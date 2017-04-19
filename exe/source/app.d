import std.stdio;
import std.string;
import std.datetime;
import std.process;
import std.file;
import std.path;
import std.conv;
import std.concurrency;
import std.random;
import std.algorithm;
import std.json;
import core.thread;
import std.typecons;
import std.array;
import std.parallelism;
import core.atomic;
import core.sys.windows.windows;

import graphite.twitter;
import imageformats;

shared string g_rootPath;
shared PrivateClock g_clock;
shared string g_configFile;
string g_statusFile;
shared bool g_forReals;
Tid g_loggingThread;
uint g_testPhotoNum = 1;
bool g_allowTweetingInDryRun = false;

shared Round g_currentRound;
TwitterInfo g_twitterInfo;
TuningConfig g_tuningConfig;

enum WarmUpTimeHandling
{
    ZeroInactive = 0,
    EqualInactive = 1,
    SurplusAfter = 2,
    SurplusBefore = 3,
}

pure Duration stripFracSeconds(Duration d)
{
    return d - dur!"nsecs"(d.split!("seconds", "nsecs").nsecs);
}

unittest
{
    assert(stripFracSeconds(dur!"msecs"(1001)) == dur!"seconds"(1));
    assert(stripFracSeconds(dur!"msecs"(1000)) == dur!"seconds"(1));
    assert(stripFracSeconds(dur!"msecs"(999)) == Duration.zero);
    assert(stripFracSeconds(dur!"msecs"(61001)) == dur!"seconds"(61));
}

pure Duration stripToMinutesOrSeconds(Duration d)
{
    auto splitResults = d.split!("minutes", "seconds")();
    if (splitResults.minutes > 0)
    {
        return dur!"minutes"(splitResults.minutes);
    }
    else
    {
        return dur!"seconds"(splitResults.seconds);
    }
}

unittest
{
    assert(stripToMinutesOrSeconds(dur!"seconds"(61)) == dur!"minutes"(1));
    assert(stripToMinutesOrSeconds(dur!"seconds"(59)) == dur!"seconds"(59));
}

//
// YYYYMMDD-HHMM.SS
//
string formatTimeToSeconds(SysTime t)
{
    return format(
               "%04d%02d%02d-%02d%02d.%02d",
               t.year,
               t.month,
               t.day,
               t.hour,
               t.minute,
               t.second);
}

//
// produces a string suitable for printing, like 2h 10m, 2h, or 10m, depending
// on how many whole hours and minutes are in the duration
//
string formatDurationToHoursMins(Duration d)
{
    assert(d >= Duration.zero);

    auto hmSplit = d.split!("hours", "minutes");
    string ret = "";

    //
    // include hours if it's there
    //
    if (hmSplit.hours > 0)
    {
        ret ~= format("%dh", hmSplit.hours);
    }

    //
    // if no hours and no minutes, then say 0 minutes
    //
    else if (hmSplit.minutes == 0)
    {
        ret = "0m";
    }

    //
    // no hours, some minutes
    //
    if (hmSplit.minutes > 0)
    {
        if (ret.length > 0)
        {
            ret ~= " ";
        }

        ret ~= format("%dm", hmSplit.minutes);
    }

    return ret;
}

unittest
{
     assert(formatDurationToHoursMins(Duration.zero) == "0m");
     assert(formatDurationToHoursMins(dur!"minutes"(60)) == "1h");
     assert(formatDurationToHoursMins(dur!"minutes"(1)) == "1m");
     assert(formatDurationToHoursMins(dur!"minutes"(61)) == "1h 1m");
     assert(formatDurationToHoursMins(dur!"seconds"(1)) == "0m");
     assert(formatDurationToHoursMins(dur!"minutes"(659)) == "10h 59m");
}

void ensureFolder(string folderPath)
{
    if (!exists(folderPath))
    {
        mkdir(folderPath);
    }
}

int executeShellWithWait(string command, Duration waitTime)
{
    auto pid = spawnShell(command);
    auto waitResult = tryWait(pid);
    Duration nextWaitDuration = dur!`seconds`(1);
    while (!waitResult.terminated && waitTime > Duration.zero)
    {
        if (nextWaitDuration > waitTime)
        {
            nextWaitDuration = waitTime;
        }

        Thread.sleep(nextWaitDuration);
        waitResult = tryWait(pid);
    }

    int exitCode;
    if (waitResult.terminated)
    {
        exitCode = waitResult.status;
    }
    else
    {
        exitCode = -10;
    }

    return exitCode;
}

void log(Args...)(string fmt, Args args)
{
    send(g_loggingThread, format(fmt, args));
}

string getConfigFileName()
{
    return (g_forReals ? "lavamite_config.json" : "lavamite_config_dry.json");
}

void fnLoggingThread()
{
    string logFolder = null;
    File logFile;

    while (true)
    {
        try
        {
            string msg = receiveOnly!string();

            SysTime currTime = g_clock.currTime;
            string output;

            //
            // this code can run before the first round has been set. in
            // that case, log a format that doesn't include round info. if
            // the current round is set, check if it is a new round, and if
            // so, open a log file in the new folder.
            //
            // only write to log file if the current round is set. write out
            // to stdout always.
            //
            // whenever starting a new round, copy in the config file at the
            // time the round was started, so afterwards you can see how the
            // chosen parameters of the round were selected. When continuing
            // a round, make sure not to overwrite the config file, since the
            // parameters were locked in before, but the config file could have
            // changed after.
            //
            if (g_currentRound !is null)
            {
                if (logFolder is null || (cmp(g_currentRound.roundFolder, logFolder) != 0))
                {
                    logFolder = g_currentRound.roundFolder;
                    logFile = File(buildPath(logFolder, "lavamite.log"), "a");

                    string roundConfigPath = buildPath(logFolder, getConfigFileName());
                    if (!std.file.exists(roundConfigPath))
                    {
                        std.file.copy(g_configFile, roundConfigPath);
                    }
                }

                output = format("%s (%s): %s", formatTimeToSeconds(currTime), g_currentRound.getRoundAndSecOffset(currTime), msg);

                logFile.writeln(output);
                logFile.flush();
            }
            else
            {
                output = format("%s: %s", formatTimeToSeconds(currTime), msg);
            }

            writeln(output);
        }
        catch (OwnerTerminated ex)
        {
            return;
        }
    }
}

//
// this thread sits in the background and takes photos periodically, to help
// with tuning. it only takes photos while actively in a round, because who
// cares what it looks like during cooldown between rounds?
//
void fnPhotoThread(Tid loggingThread, shared LavaCam camera)
{
    g_loggingThread = loggingThread;

    bool lampOn = false;

    void setLampState(bool on)
    {
        lampOn = on;
    }

    try
    {
        while (true)
        {
            //
            // when it rains, it pours; drain all messages available
            //
            while (receiveTimeout(Duration.zero(), &setLampState)) {}

            if (lampOn)
            {
                try
                {
                    camera.takePhotoToPhotosFolder();
                }
                catch (TakePhotoException ex)
                {
                    //
                    // in particular, log the output of the failed takephoto
                    // command
                    //
                    log("failed to take photo: %s\n%s", ex, ex.output);
                }
                catch (Throwable ex)
                {
                    log("exception in photo thread: %s", ex);
                }

                //
                // wait a while until taking the next picture
                //
                Duration sleepTimeUntilNextPhoto = dur!`minutes`(1);
                if (!g_forReals)
                {
                    sleepTimeUntilNextPhoto = getDrySleepDuration(sleepTimeUntilNextPhoto);
                }

                receiveTimeout(sleepTimeUntilNextPhoto, &setLampState);
            }
            else
            {
                //
                // if the lamp is off, we have nothing to do until someone
                // tells us the lamp state has changed
                //
                lampOn = receiveOnly!bool();
            }
        }
    }
    catch (OwnerTerminated ex)
    {
        return;
    }
}

void usage(string msg)
{
    writefln(
`Error: %s
Usage: lavamite.exe [-com com_port_name] [-cam device_id] [-dry]
    -com: specify COM port to use to control, e.g. COM3
    -cam: ID of the camera device to use for photos. use takephoto.exe -enum
          to see which devices are present
    -enumCams: enumerate camera devices on this computer, then exit
    -live: if not specified, only does a dry run with output`,
    msg);
}

Duration getDrySleepDuration(Duration original)
{
    if (original > dur!"minutes"(15))
    {
        return dur!"seconds"(5);
    }
    else
    {
        return dur!"msecs"(100);
    }
}

//
// wrap a sleep function so that we can synthetically advance the clock when
// in dry mode. during dry mode we sleep for 5 seconds regardless of how long
// was requested
//
void privateSleep(Duration d)
{
    Duration originalDuration = d;

    if (!g_forReals)
    {
        d = getDrySleepDuration(originalDuration);
    }

    Thread.sleep(d);
    g_clock.advance(originalDuration);
}

//
// wrap receiveTimeout so we can synthetically advance the clock in dry mode.
// if we notice that the receive was actually fulfilled, only advance the
// timer halfway, under the assumption that the entire wait period did not
// elapse
//
alias Tuple!(bool, "isExitRequested", Duration, "timeSlept") sleepHowLongWithExitCheck_Return;
sleepHowLongWithExitCheck_Return sleepHowLongWithExitCheck(Duration d)
{
    assert(!d.isNegative());

    Duration fakeSleepDuration = d;

    if (!g_forReals)
    {
        d = getDrySleepDuration(d);
    }

    SysTime tBeforeSleep = g_clock.currTime;

    bool didReceive = receiveTimeout(d, (bool dummy) { });

    if (didReceive)
    {
        fakeSleepDuration /= 2;
    }

    g_clock.advance(fakeSleepDuration);

    sleepHowLongWithExitCheck_Return ret;
    ret.isExitRequested = didReceive;
    ret.timeSlept = g_clock.currTime - tBeforeSleep;
    return ret;
}

//
// simple wrapper for callers who don't care about how long they slept for
// out of the requested duration
//
bool sleepWithExitCheck(Duration d)
{
    auto sleepResult = sleepHowLongWithExitCheck(d);
    return sleepResult.isExitRequested;
}

//
// Steal formula from Wikipedia to calculate grayscale based on RGB values
//
float averageGrayscale(ref IFImage image)
{
    float average = 0;
    immutable uint totalPixels = image.w * image.h;
    for (uint pixelIndex = 0; pixelIndex < totalPixels; pixelIndex++)
    {
        uint valueIndex = pixelIndex * image.c;
        float grayscale = cast(int)(0.299 * image.pixels[valueIndex]) +
                          cast(int)(0.587 * image.pixels[valueIndex+1]) +
                          cast(int)(0.114 * image.pixels[valueIndex+2]);
        average *= pixelIndex;
        average += grayscale;
        average /= (pixelIndex+1);
    }

    return average;
}

int main(string[] args)
{
    g_forReals = false;

    g_clock = PrivateClock(Clock.currTime);

    g_rootPath = dirName(thisExePath());

    g_loggingThread = spawn(&fnLoggingThread);

    string takePhotoPath = buildPath(g_rootPath, "takephoto.exe");

    //
    // parse all command line arguments
    //
    string comPort = "COM3";
    int camDevice = -1;
    for (int i = 1; i < args.length; i++)
    {
        if (cmp(args[i], "-com") == 0)
        {
            i++;
            if (i < args.length)
            {
                comPort = args[i];
            }
            else
            {
                usage("need argument for -com");
                return 1;
            }
        }
        else if (cmp(args[i], "-cam") == 0)
        {
            i++;
            if (i < args.length)
            {
                camDevice = to!int(args[i]);
            }
            else
            {
                usage("need argument for -cam");
                return 1;
            }
        }
        else if (cmp(args[i], "-enumCams") == 0)
        {
            return LavaCam.enumerateCameras(takePhotoPath);
        }
        else if (cmp(args[i], "-live") == 0)
        {
            g_forReals = true;
        }
        else if (cmp(args[i], "-dryTweet") == 0)
        {
            g_allowTweetingInDryRun = true;
        }
        else if (cmp(args[i], "-httpProxy") == 0)
        {
            i++;
            if (i < args.length)
            {
                Twitter.proxy = args[i];
            }
            else
            {
                usage("need argument for -httpProxy");
                return 1;
            }
        }
        else
        {
            usage(format("unknown argument %s", args[i]));
            return 1;
        }
    }

    shared LavaCam camera = cast(shared LavaCam)(new LavaCam(camDevice, takePhotoPath));

    g_configFile = buildPath(g_rootPath, getConfigFileName());
    g_statusFile = buildPath(g_rootPath, (g_forReals ? "lavamite_status.json" : "lavamite_status_dry.json"));

    processStatusFile();
    processConfigFile();

    //
    // at this point, g_currentRound is set
    //

    DWORD baudRate = CBR_9600;
    ControllablePowerSwitch powerSwitch = new ControllablePowerSwitch(comPort, baudRate);

    log("Attached to power switch on %s at %d baud", comPort, baudRate);

    //
    // separate thread to wait for "quit", which sends a message back to the
    // main thread, and upon which we will break out and quit the program
    //
    spawn(
        (Tid mainThread)
        {
            writeln("Type quit to exit");

            try
            {
                while (true)
                {
                    string line = chomp(readln());
                    if (icmp(line, "quit") == 0)
                    {
                        send(mainThread, true);
                        return;
                    }
                }
            }
            catch (OwnerTerminated ex)
            {
                return;
            }
        },
        thisTid);

    //
    // have a thread sitting by, taking a photo periodically, so we can see
    // how the lamp progresses over time. This thread will exit when the
    // main program exits
    //
    Tid photoTid = spawn(&fnPhotoThread, g_loggingThread, camera);
    void notifyPhotoThread(bool lampState)
    {
        send(photoTid, lampState);
    }

    //
    // the main part of the program, in which we run "rounds" one after
    // another. A round consists of a time to have the lamp on, a time to get
    // the lamp bubbling normally, and a time to let it cool off
    //
    do
    {
        try
        {
            bool inSomePhase = false;

            //
            // on every iteration of the main loop, we will be in one of 2
            // situations:
            //
            // 1. loaded last round info from a file, so we continue from the
            //    point where the program had last left off. in
            //    processStatusFile, we adjust the last round info so that
            //    its start time is positioned before the current time, so
            //    we can use the current time as an accurate offset into the
            //    round
            //
            // 2. current time is after the end of the last round, so we
            //    start a new round
            //
            if (!g_currentRound.wholeRoundInterval.contains(g_clock.currTime))
            {
                //
                // choose all the parameters for the new round: cooldown
                // time, warmup time, warmup behavior, and total time till
                // stabilization. these parameters have typically been deduced
                // empirically, and are read from a config file
                //
                Duration cooldownTime = g_tuningConfig.rangeCooldownTime.randomDuration!"minutes"();

                //
                // The time to get to steady state, which is known to get the
                // lamp bubbling nicely
                //
                Duration stabilizationTime = g_tuningConfig.stabilizationTime;

                //
                // Probably the most important parameters relate to how warm-up
                // time is handled. First we have to decide which warm-up
                // behavior we want, then the amount of time to use.
                //
                // ZeroInactive: we keep the lamp active for the entire
                // duration we choose, and don't turn it off at any time in the
                // middle.
                //
                // EqualInactive: we alternate the lamp turning on and off at
                // random intervals. The amount of time the lamp spends off
                // during this phase is the same as on.
                //
                // SurplusAfter: we alternate turning the lamp on and off, but
                // spend more time on than off. The surplus time is spent on
                // after all the "off" time has been exhausted
                //
                // SurplusBefore: we alternate turning the lamp on and off, but
                // spend more time on than off. The surplus active time is
                // spent up front, then it alternates as in the case of
                // EqualInactive for the rest of the time
                //
                Duration warmUpActiveTime;
                Duration warmUpInactiveTime;

                WarmUpTimeHandling warmUpTimeHandling = cast(WarmUpTimeHandling) dice(g_tuningConfig.choicesWarmUpTimeHandling);
                final switch(warmUpTimeHandling)
                {
                    case WarmUpTimeHandling.ZeroInactive:
                        warmUpActiveTime = g_tuningConfig.rangeWarmUpActiveTimeWithZeroInactive.randomDuration!"seconds"();
                        warmUpInactiveTime = Duration.zero;
                    break;

                    case WarmUpTimeHandling.EqualInactive:
                        warmUpActiveTime = g_tuningConfig.rangeWarmUpActiveTimeWithEqualInactive.randomDuration!"seconds"();
                        warmUpInactiveTime = warmUpActiveTime;
                    break;

                    case WarmUpTimeHandling.SurplusAfter:
                        warmUpActiveTime = g_tuningConfig.rangeWarmUpActiveTimeWithSurplusAfter.randomDuration!"seconds"();

                        ulong warmUpActiveSeconds = warmUpActiveTime.total!"seconds"();
                        warmUpInactiveTime = dur!"seconds"((g_tuningConfig.rangeWarmUpInactivePercentOfActiveSurplusAfter.random() * warmUpActiveSeconds) / 100);
                    break;

                    case WarmUpTimeHandling.SurplusBefore:
                        warmUpActiveTime = g_tuningConfig.rangeWarmUpActiveTimeWithSurplusBefore.randomDuration!"seconds"();

                        ulong warmUpActiveSeconds = warmUpActiveTime.total!"seconds"();
                        warmUpInactiveTime = dur!"seconds"((g_tuningConfig.rangeWarmUpInactivePercentOfActiveSurplusBefore.random() * warmUpActiveSeconds) / 100);
                    break;
                }

                //
                // thus enters the new round
                //
                setCurrentRound(
                    new Round(
                        g_currentRound.number + 1,   // round number
                        g_clock.currTime,            // start time
                        g_clock.currTime,            // original start time
                        g_currentRound.cooldownTime, // prior cooldown time
                        warmUpActiveTime,            // warmup active time
                        warmUpInactiveTime,          // warmup inactive time
                        warmUpTimeHandling,          // warmup time handling
                        warmUpActiveTime,            // remaining active
                        warmUpInactiveTime,          // remaining inactive
                        stabilizationTime,           // stabilization time
                        cooldownTime,                // cooldown time
                        null                         // posted image tweet id
                        ));

                log("********* STARTING ROUND: %s", g_currentRound.formatForLogging());
            }
            else
            {
                log("********* CONTINUING ROUND, %s in. %s", 
                    stripFracSeconds(g_clock.currTime - g_currentRound.startTime),
                    g_currentRound.formatForLogging());
            }

            //
            // warm-up phase: wait for a while to warm up the lamp partway, but
            // not so much that it goes into "steady state" (with bubbles
            // continually rising and falling). the whole point of this program
            // is to capture the formations before it's stabilized
            //
            if (g_currentRound.warmUpInterval.contains(g_clock.currTime))
            {
                inSomePhase = true;

                //
                // if the current time is within the warm-up interval, then
                // it stands to reason that there should be remaining time to
                // warm up.
                //
                assert(g_currentRound.remainingWarmUpActiveTime > Duration.zero);

                //
                // photos are always being taken during warm-up and
                // stabilization
                //
                notifyPhotoThread(true);

                //
                // if we have more active time left than total original
                // inactive time, then that means we have "surplus" active
                // time. this block handles the case where we've chosen
                // above to consume this surplus active time all at the
                // beginning
                //
                if (g_currentRound.warmUpTimeHandling == WarmUpTimeHandling.SurplusBefore && g_currentRound.remainingWarmUpActiveTime > g_currentRound.warmUpInactiveTime)
                {
                    //
                    // consume enough to bring the remaining active time
                    // down to the same amount of inactive time
                    //
                    Duration activeTimeAtBeginningDuration = g_currentRound.remainingWarmUpActiveTime - g_currentRound.warmUpInactiveTime;

                    log("consuming surplus active time at the beginning: %s", activeTimeAtBeginningDuration);

                    writeStatusFile();
                    powerSwitch.turnOnPower();
                    auto sleepResult = sleepHowLongWithExitCheck(activeTimeAtBeginningDuration);
                    g_currentRound.deductRemainingWarmUpActiveTime(sleepResult.timeSlept);

                    if (sleepResult.isExitRequested)
                    {
                        log("exiting during surplus active time before. remaining surplus-before time: %s", activeTimeAtBeginningDuration - sleepResult.timeSlept);
                        break;
                    }
                }

                //
                // this loop consumes the warm-up active time, either in one
                // continuous length or by alternating active and inactive
                // periods, depending on what was chosen above
                //
                bool isExitRequested = false;
                while (g_currentRound.remainingWarmUpActiveTime > Duration.zero)
                {
                    //
                    // start each active/inactive cycle with the lamp on. if
                    // we are doing a 0-inactive time cycle, then this loop
                    // will only be called once
                    //
                    powerSwitch.turnOnPower();

                    //
                    // if there is enough inactive time left to be consumed, do
                    // one period of active time followed by one period of
                    // inactive time
                    //
                    // else (if there isn't enough inactive time left), just
                    // consume all the rest of the active time. That is the
                    // normal codepath for a ZeroInactive round, too.
                    //
                    if (g_currentRound.remainingWarmUpInactiveTime > g_tuningConfig.rangeActiveCycleTime.min)
                    {
                        //
                        // leave on for some active time
                        //
                        Duration thisCycleActiveTime =
                            min(
                                g_tuningConfig.rangeActiveCycleTime.randomDuration!"seconds"(),
                                g_currentRound.remainingWarmUpActiveTime);

                        log("active cycle time = %s. remaining active: %s, remaining inactive: %s", thisCycleActiveTime, g_currentRound.remainingWarmUpActiveTime, g_currentRound.remainingWarmUpInactiveTime);

                        writeStatusFile();
                        auto sleepResult = sleepHowLongWithExitCheck(thisCycleActiveTime);
                        g_currentRound.deductRemainingWarmUpActiveTime(sleepResult.timeSlept);

                        isExitRequested = sleepResult.isExitRequested;
                        if (isExitRequested)
                        {
                            break;
                        }

                        //
                        // now leave off for some inactive time
                        //
                        Duration thisCycleInactiveTime =
                            min(
                                g_tuningConfig.rangeActiveCycleTime.randomDuration!"seconds"(),
                                g_currentRound.remainingWarmUpInactiveTime);

                        powerSwitch.turnOffPower();
                        log("inactive cycle time = %s. remaining active: %s, remaining inactive: %s", thisCycleInactiveTime, g_currentRound.remainingWarmUpActiveTime, g_currentRound.remainingWarmUpInactiveTime);

                        writeStatusFile();
                        sleepResult = sleepHowLongWithExitCheck(thisCycleInactiveTime);
                        g_currentRound.deductRemainingWarmUpInactiveTime(sleepResult.timeSlept);

                        isExitRequested = sleepResult.isExitRequested;
                        if (isExitRequested)
                        {
                            break;
                        }
                    }
                    else
                    {
                        log("Leaving on to consume all warmup active time: %s", g_currentRound.remainingWarmUpActiveTime);
                        writeStatusFile();
                        auto sleepResult = sleepHowLongWithExitCheck(g_currentRound.remainingWarmUpActiveTime);
                        g_currentRound.deductRemainingWarmUpActiveTime(sleepResult.timeSlept);

                        isExitRequested = sleepResult.isExitRequested;
                        if (isExitRequested)
                        {
                            break;
                        }
                    }
                }

                if (isExitRequested)
                {
                    log("Exiting during warmup. Remaining active time: %s, inactive time: %s", g_currentRound.remainingWarmUpActiveTime, g_currentRound.remainingWarmUpInactiveTime);
                    break;
                }

                //
                // with the lamp warmed up as much as we want, take the money
                // shot and post it for the world to see
                //
                powerSwitch.turnOnPower();
                takeAndPostPhoto(camera);
            }

            //
            // finish warming up the lamp all the way, so it cools down into
            // its settled state rather than freezing in a formation.
            //
            bool completingStabilization = false;
            if (g_clock.currTime < g_currentRound.stabilizationInterval.end)
            {
                inSomePhase = true;

                powerSwitch.turnOnPower();
                notifyPhotoThread(true);

                //
                // when continuing a round, determine how far into the round
                // it is now. calculate the time remaining in this phase of
                // the round and only wait for that long.
                //
                // for new rounds, this will be the whole time for the phase,
                // since the time is currently just after the start of the
                // phase.
                //
                // add 5 sec to the time we wait, which will comfortably put
                // us into the next phase, once this phase is completed
                //
                Duration remainingStabilizationTime = g_currentRound.stabilizationInterval.end - g_clock.currTime + dur!"seconds"(5);
                log("Leaving on for remaining time to stabilization, %s", stripFracSeconds(remainingStabilizationTime));

                writeStatusFile();
                if (sleepWithExitCheck(remainingStabilizationTime))
                {
                    break;
                }

                completingStabilization = true;
            }

            //
            // always turn off lamp at the end of stabilization regardless of
            // which phases we're skipping
            //
            powerSwitch.turnOffPower();
            notifyPhotoThread(false);

            if (g_clock.currTime < g_currentRound.cooldownInterval.end)
            {
                inSomePhase = true;

                // Only post the video if we just finished the stabilization
                // phase. If we restart straight into cooldown, don't post it
                // again.
                if (completingStabilization && g_tuningConfig.isVideoEnabled)
                {
                    encodeAndPostVideoOfRound();
                }

                Duration remainingCooldownTime = g_currentRound.cooldownInterval.end - g_clock.currTime + dur!"seconds"(5);
                log("Cooling down for %s until next session", stripFracSeconds(remainingCooldownTime));
                writeStatusFile();
                if (sleepWithExitCheck(remainingCooldownTime))
                {
                    break;
                }
            }

            assert(inSomePhase);
        }
        catch (Throwable ex)
        {
            log("exception. will continue with next round. %s", ex);
        }

        processConfigFile();
    } while (true);

    writeStatusFile();

    log("Exiting...");
    powerSwitch.turnOffPower();

    return 0;
}

//
// The status file has two things that we use:
//
// lastRoundInfo: optional. contains the information about the last round
// that we did, so we can pick up where we left off
//
// lastActionTime: optional. along with last round info, lets us know how far
// into the last round the program was running, to let us pick up where we
// left off
//
void processStatusFile()
{
    shared Round rs;
    SysTime lastActionTime = g_clock.currTime;

    if (exists(g_statusFile))
    {
        JSONValue root;

        try
        {
            root = parseJSON(readText(g_statusFile));
        }
        catch (Throwable ex)
        {
            log("Malfomed JSON in status file %s.", g_statusFile);
            throw ex;
        }

        try
        {
            JSONValue* jvLAT = "lastActionTime" in root.object;
            if (jvLAT !is null)
            {
                lastActionTime = SysTime.fromISOString(jvLAT.str);
            }
            else
            {
                throw new Exception(format("Well-formed JSON file %s missing malformed lastActionTime (should be ISO string). Must fix.", g_statusFile));
            }
        }
        catch (Throwable ex)
        {
            log("Well-formed JSON file %s with malformed lastActionTime (should be ISO string). Must fix.", g_statusFile);
            throw ex;
        }

        try
        {
            JSONValue* lastRoundInfo = "lastRoundInfo" in root.object;
            if (lastRoundInfo !is null)
            {
                rs = cast(shared Round)Round.fromJSON(*lastRoundInfo);
            }
            else
            {
                throw new Exception(format("Well-formed JSON file %s missing last round info. Must fix.", g_statusFile));
            }
        }
        catch (Throwable ex)
        {
            log("Well-formed JSON file %s with incorrect last round info.", g_statusFile);
            throw ex;
        }
    }
    else
    {
        log("missing status file %s. starting from scratch.", g_statusFile);

        rs = cast(shared Round) new Round(
                0,                    // round number
                g_clock.currTime,     // start time
                g_clock.currTime,     // original start time
                Duration.zero(),      // prior cooldown time
                dur!"seconds"(1),     // warmup active time
                Duration.zero(),      // warmup inactive time
                WarmUpTimeHandling.ZeroInactive,
                dur!"seconds"(1),     // remaining warmup active time
                Duration.zero(),      // remaining warmup inactive
                dur!"seconds"(1),     // stabilization time
                dur!"hours"(4),       // cooldown time
                null                  // posted image tweet id
                );

        //
        // if missing the status file, put us 1 second after the end of the
        // last round
        //
        lastActionTime = rs.wholeRoundInterval.end + dur!"seconds"(1);
    }

    //
    // this is really important. shift the round that we loaded from file
    // to be offset from the current time. We calculate how far we made it
    // into the last round, then adjust the startTime of the round to
    // position the current time at that point.
    //
    setCurrentRound(
        new Round(
            rs.number,
            g_clock.currTime - (lastActionTime - rs.startTime),
            rs.originalStartTime,
            rs.priorCooldownTime,
            rs.warmUpActiveTime,
            rs.warmUpInactiveTime,
            rs.warmUpTimeHandling,
            rs.remainingWarmUpActiveTime,
            rs.remainingWarmUpInactiveTime,
            rs.stabilizationTime,
            rs.cooldownTime,
            rs.postedImageTweetId));
}

//
// The config file has two settings that we use:
//
// twitterInfo: required. contains the authentication information for posting
// to twitter
//
// tuningConfig: required. parameters to control the random values used in
// making new rounds
//
void processConfigFile()
{
    TwitterInfo twitterInfo;
    TuningConfig tuningConfig;

    if (exists(g_configFile))
    {
        JSONValue root;

        try
        {
            root = parseJSON(readText(g_configFile));
        }
        catch (Throwable ex)
        {
            log("Malfomed JSON in config file %s. Must contain Twitter info and tuning config.", g_configFile);
            throw ex;
        }

        try
        {
            JSONValue jsonTwitterInfo = root.object["twitterInfo"];
            twitterInfo = TwitterInfo.fromJSON(jsonTwitterInfo);
        }
        catch (Throwable ex)
        {
            log("Well-formed JSON file %s that does not contain Twitter info. Must fix.", g_configFile);
            throw ex;
        }

        try
        {
            JSONValue jsonTuningConfig = root.object["tuningConfig"];
            tuningConfig = TuningConfig.fromJSON(jsonTuningConfig);
        }
        catch (Throwable ex)
        {
            log("Well-formed JSON file %s that does not contain tuning config. Must fix.", g_configFile);
            throw ex;
        }
    }
    else
    {
        throw new Exception(format("Missing JSON config file %s. Must contain Twitter info and tuning config.", g_configFile));
    }

    g_twitterInfo = twitterInfo;
    g_tuningConfig = tuningConfig;
}

void writeStatusFile()
{
    JSONValue root = JSONValue(
        [
            "lastRoundInfo" : g_currentRound.toJSON(),
            "lastActionTime": JSONValue(g_clock.currTime.toISOString()),
        ]);

    File outfile = File(g_statusFile, "w");
    outfile.write(root.toPrettyString());
}

//
// every time the round changes, we also start storing photos and logs in a
// new folder, so create that.
//
// also write out the new round info to file so it can be loaded later
//
void setCurrentRound(Round r)
{
    // TODO: need to understand this cast better
    shared Round rs = cast(shared Round)r;
    ensureFolder(rs.roundFolder);

    g_currentRound = rs;
    writeStatusFile();
}

string tweetTextAndMedia(string textToTweet, string inReplyToId, string mediaPath, string mimeType, Twitter.MediaCategory mediaCategory)
{
    string[string] parms;
    parms["status"] = textToTweet;

    if (inReplyToId !is null)
    {
        parms[`in_reply_to_status_id`] = inReplyToId;
    }

    log(`Tweeting "%s" in reply to %s with media %s (%s, %s)`, textToTweet, inReplyToId !is null ? inReplyToId : `nothing`, mediaPath, mimeType, mediaCategory);

    string tweetId;
    if (g_forReals || g_allowTweetingInDryRun)
    {
        immutable uint tweetAttempts = 5;
        foreach (uint i; 1 .. tweetAttempts+1)
        {
            try
            {
                JSONValue response = parseJSON(Twitter.statuses.updateWithMedia(g_twitterInfo.accessToken, mediaPath, mimeType, mediaCategory, parms));
                log("%s", response.toPrettyString());
                tweetId = response[`id_str`].str;
                break;
            }
            catch (Throwable ex)
            {
                string msg = format("failure number %d to tweet: %s", i, ex);
                if (i == tweetAttempts)
                {
                    throw new Exception(msg);
                }
                else
                {
                    log(msg);
                }
            }
        }
    }
    else
    {
        tweetId = format("%u", uniform(1000000, 2000000));
    }

    return tweetId;
}

string tweetTextAndPhoto(string textToTweet, string photoPath)
{
    return tweetTextAndMedia(textToTweet, null, photoPath, `image/jpeg`, Twitter.MediaCategory.TweetImage);
}

string tweetTextAndVideo(string textToTweet, string postedImageTweetId, string photoPath)
{
    return tweetTextAndMedia(textToTweet, postedImageTweetId, photoPath, `video/mp4`, Twitter.MediaCategory.TweetVideo);
}

void takeAndPostPhoto(shared LavaCam camera)
{
    immutable uint numPhotoTries = 5;

    string photoPath;
    foreach (uint i; 1 .. numPhotoTries+1)
    {
        try
        {
            photoPath = camera.takePhotoToPhotosFolder("----POSTED", true);
            break;
        }
        catch (Throwable ex)
        {
            string msg = format("failure number %d to take photo: %s", i, ex);
            if (i == numPhotoTries)
            {
                throw new Exception(msg);
            }
            else
            {
                log(msg);
            }
        }
    }

    Duration averageCycleTime = stripToMinutesOrSeconds(((g_tuningConfig.rangeActiveCycleTime.max - g_tuningConfig.rangeActiveCycleTime.min) / 2));
    assert(averageCycleTime < dur!"hours"(1));
    assert(averageCycleTime > dur!"seconds"(1));

    Duration surplusActiveTime = g_currentRound.warmUpActiveTime - g_currentRound.warmUpInactiveTime;

    string textToTweet;
    final switch (g_currentRound.warmUpTimeHandling)
    {
        case WarmUpTimeHandling.ZeroInactive:
        {
            textToTweet = format(
                "Round %d. Continuous warm-up time: %s.",
                g_currentRound.number,
                formatDurationToHoursMins(g_currentRound.warmUpActiveTime));
        }
        break;

        case WarmUpTimeHandling.EqualInactive:
        {
            //
            // total "lamp on" time is active time + inactive time
            //
            textToTweet = format(
                "Round %d. Alternating on and off every ~%s for %s.",
                g_currentRound.number,
                averageCycleTime,
                formatDurationToHoursMins(g_currentRound.warmUpActiveTime + g_currentRound.warmUpInactiveTime));
        }
        break;

        case WarmUpTimeHandling.SurplusAfter:
        {
            assert(surplusActiveTime > Duration.zero);

            //
            // total "lamp on" time is active time + inactive time. since
            // active time is broken up into surplus + (same duration as
            // inactive time), this becomes 2x inactive time + surplus.
            //
            textToTweet = format(
                "Round %d. Alternating on and off every ~%s for %s, then on for %s.",
                g_currentRound.number,
                averageCycleTime,
                formatDurationToHoursMins(g_currentRound.warmUpInactiveTime * 2),
                formatDurationToHoursMins(surplusActiveTime));
        }
        break;

        case WarmUpTimeHandling.SurplusBefore:
        {
            assert(surplusActiveTime > Duration.zero);

            //
            // same comment as above about 2x inactive time + surplus
            //
            textToTweet = format(
                "Round %d. On for %s, then alternating on and off every ~%s for %s.",
                g_currentRound.number,
                formatDurationToHoursMins(surplusActiveTime),
                averageCycleTime,
                formatDurationToHoursMins(g_currentRound.warmUpInactiveTime * 2));
        }
        break;
    }

    g_currentRound.postedImageTweetId = tweetTextAndPhoto(textToTweet, photoPath);
}

void encodeAndPostVideoOfRound()
{
    // out of 255 max
    immutable float DARKNESS_CUTOFF = 15.0;

    string inputFolder = g_currentRound.roundFolder;
    string outputVideoFilename = buildPath(inputFolder, "round.mp4");

    string encodingTempDir = buildPath(tempDir(), "lavamite_encode");
    try
    {
        rmdirRecurse(encodingTempDir);
        Thread.sleep(dur!`seconds`(1));
    }
    catch (Throwable ex)
    {
        log("Exception removing temp dir");
    }

    mkdirRecurse(encodingTempDir);

    uint numSkippedBlackFrames = 0;
    foreach (string photoFilename; dirEntries(inputFolder, `*.jpg`, SpanMode.shallow))
    {
        IFImage im = read_image(photoFilename, ColFmt.RGB);
        if (averageGrayscale(im) >= DARKNESS_CUTOFF)
        {
            string includedPhotoFilename = buildPath(encodingTempDir, baseName(photoFilename));
            log("copying from %s to %s", photoFilename, includedPhotoFilename);
            std.file.copy(photoFilename, includedPhotoFilename);
        }
        else
        {
            log("skipping %s because it's too dark", photoFilename);
            numSkippedBlackFrames++;
        }
    }

    uint frameNumber = 0;
    foreach (string filename; dirEntries(encodingTempDir, `*_r*.jpg`, SpanMode.shallow))
    {
        string frameFilename = buildPath(encodingTempDir, format(`%u.jpg`, frameNumber));
        log("renaming from %s to %s", baseName(filename), baseName(frameFilename));
        std.file.rename(filename, frameFilename);
        frameNumber++;
    }

    assert(g_tuningConfig.videoBitrate != 0);
    string ffmpegCommand = format(`%s -y -framerate 13 -i %s\%%d.jpg -c:v libx264 -preset veryslow -b:v %u %s`, g_tuningConfig.ffmpegPath, encodingTempDir, g_tuningConfig.videoBitrate, outputVideoFilename);
    log(`%s`, ffmpegCommand);
    auto ffmpegResult = executeShell(ffmpegCommand);
    log(`ffmpeg result: %s`, ffmpegResult);

    assert(g_currentRound.postedImageTweetId !is null);
    string tweetText;
    if (numSkippedBlackFrames > 0)
    {
        tweetText = format(`Round %u timelapse: %u frames, 1 min apart. Skipped %u dark frames.`, g_currentRound.number, frameNumber, numSkippedBlackFrames);
    }
    else
    {
        tweetText = format(`Round %u timelapse: %u frames, 1 min apart.`, g_currentRound.number, frameNumber);
    }

    tweetTextAndVideo(tweetText, g_currentRound.postedImageTweetId, outputVideoFilename);
}

//
// encapsulates turning on and off the Arduino microcontroller that in turn
// controls the power to the lamp. it is controlled over a COM port
//
class ControllablePowerSwitch
{
    private HANDLE m_hCOMPort;
    private DWORD m_baudRate;
    private static immutable Duration initTime = dur!"seconds"(10);

    this(string portName, uint baud)
    {
        m_baudRate = baud;

        wchar* wPortName = cast(wchar*) (wtext(format("//./%s", portName)) ~ "\0"w);

        //
        // don't even touch the port in dry runs, because it causes the power
        // to flicker
        //
        if (g_forReals)
        {
            m_hCOMPort = CreateFileW(
                            wPortName,
                            GENERIC_READ | GENERIC_WRITE,
                            0,
                            null,
                            OPEN_EXISTING,
                            FILE_ATTRIBUTE_NORMAL,
                            null);

            if (m_hCOMPort == INVALID_HANDLE_VALUE)
            {
                throw new Exception(format("failed to open COM port %s: %d", portName, GetLastError()));
            }

            //
            // Since we have an exclusive lock on the file with the
            // CreateFile call, nobody else should be able to set the
            // parameters of the COM port, so we only need to do this once.
            //
            setCOMPortParameters();
        }
        else
        {
            m_hCOMPort = INVALID_HANDLE_VALUE;
        }

        log("Waiting for %s for microcontroller to initialize", initTime);
        privateSleep(initTime);
    }

    ~this()
    {
        if (m_hCOMPort != INVALID_HANDLE_VALUE)
        {
            CloseHandle(m_hCOMPort);
            m_hCOMPort = INVALID_HANDLE_VALUE;
        }
    }

    private void setCOMPortParameters()
    {
        DCB dcb;
        if (!GetCommState(m_hCOMPort, &dcb))
        {
            throw new Exception(format("failed GetCommState: %d", GetLastError()));
        }

        //log("Previous baud: %d, byteSize: %d, parity: %d, stopbits: %d", dcb.m_BaudRate, dcb.ByteSize, dcb.Parity, dcb.StopBits);

        dcb.BaudRate = m_baudRate;    // set the baud rate
        dcb.ByteSize = 8;             // data size, xmit, and rcv
        dcb.Parity = NOPARITY;        // no parity bit
        dcb.StopBits = ONESTOPBIT;    // one stop bit

        if (!SetCommState(m_hCOMPort, &dcb))
        {
            throw new Exception(format("failed SetCommState: %d", GetLastError()));
        }
    }

    private uint sendBytes(char[] bytes)
    {
        DWORD cb = 0;

        if (g_forReals)
        {
            if (!WriteFile(
                m_hCOMPort,
                cast(void*) bytes,
                cast(uint) bytes.length,
                &cb,
                null))
            {
                throw new Exception(format("failed WriteFile: %d", GetLastError()));
            }
        }

        return cb;
    }

    public void turnOnPower()
    {
        log("turning on power");
        sendBytes("switch_1".dup);
    }

    public void turnOffPower()
    {
        log("turning off power");
        sendBytes("switch_0".dup);
    }
}

//
// this is a wrapper around the current time that lets us advance time
// manually in dry run mode, so we don't have to wait multiple hours to see
// results
//
// In dry run mode, we return the synthesized clock value for the current
// time, which is advanced by the advance() function, usually during sleep
// type calls. in live mode, we simply return the real time
//
struct PrivateClock
{
    private ulong m_currTime;

    public this(SysTime init)
    {
        m_currTime = init.stdTime;
    }

    public shared void advance(Duration d)
    {
        m_currTime = (SysTime(m_currTime) + d).stdTime;
    }

    @property shared SysTime currTime()
    {
        if (g_forReals)
        {
            return Clock.currTime;
        }
        else
        {
            return SysTime(m_currTime);
        }
    }
}

class Round
{
    private uint m_number;
    private long m_startTime;
    private long m_originalStartTime;
    private Duration m_priorCooldownTime;
    private Duration m_warmUpActiveTime;
    private Duration m_warmUpInactiveTime;
    private WarmUpTimeHandling m_warmUpTimeHandling;
    private Duration m_remainingWarmUpActiveTime;
    private Duration m_remainingWarmUpInactiveTime;
    private Duration m_stabilizationTime;
    private Duration m_cooldownTime;
    private string m_postedImageTweetId;
    private string m_roundFolder;

    public this(
        uint number,
        SysTime startTime,
        SysTime originalStartTime,
        Duration priorCooldownTime,
        Duration warmUpActiveTime,
        Duration warmUpInactiveTime,
        WarmUpTimeHandling warmUpTimeHandling,
        Duration remainingWarmUpActiveTime,
        Duration remainingWarmUpInactiveTime,
        Duration stabilizationTime,
        Duration cooldownTime,
        string postedImageTweetId)
    {
        this.m_number = number;
        m_startTime = startTime.stdTime;
        m_originalStartTime = originalStartTime.stdTime;

        m_priorCooldownTime = priorCooldownTime;
        m_warmUpActiveTime = warmUpActiveTime;
        m_warmUpInactiveTime = warmUpInactiveTime;
        m_warmUpTimeHandling = warmUpTimeHandling;
        m_remainingWarmUpActiveTime = remainingWarmUpActiveTime;
        m_remainingWarmUpInactiveTime = remainingWarmUpInactiveTime;
        m_stabilizationTime = stabilizationTime;
        m_cooldownTime = cooldownTime;

        m_postedImageTweetId = postedImageTweetId;

        m_roundFolder = buildPath(g_rootPath, format("round_%04d_%s", number, formatTimeToSeconds(originalStartTime)));
    }

    @property public shared pure uint number()
    {
        return m_number;
    }

    @property public shared pure SysTime startTime()
    {
        return SysTime(m_startTime);
    }

    @property public shared pure SysTime originalStartTime()
    {
        return SysTime(m_originalStartTime);
    }

    @property public shared pure Duration priorCooldownTime()
    {
        return m_priorCooldownTime;
    }

    //
    // warm-up time, then stabilization time, then cooldown time
    //
    @property public shared pure Interval!SysTime wholeRoundInterval()
    {
        return Interval!SysTime(startTime(), warmUpInterval().length + stabilizationInterval().length + cooldownInterval().length);
    }

    @property public shared pure Duration warmUpActiveTime()
    {
        return m_warmUpActiveTime;
    }

    @property public shared pure Duration warmUpInactiveTime()
    {
        return m_warmUpInactiveTime;
    }

    @property public shared pure WarmUpTimeHandling warmUpTimeHandling()
    {
        return m_warmUpTimeHandling;
    }

    @property public shared pure Duration remainingWarmUpActiveTime()
    {
        return m_remainingWarmUpActiveTime;
    }

    @property public shared pure Duration remainingWarmUpInactiveTime()
    {
        return m_remainingWarmUpInactiveTime;
    }

    public shared Duration deductRemainingWarmUpActiveTime(Duration d)
    {
        return deductTime(&m_remainingWarmUpActiveTime, d);
    }

    public shared Duration deductRemainingWarmUpInactiveTime(Duration d)
    {
        return deductTime(&m_remainingWarmUpInactiveTime, d);
    }

    private static Duration deductTime(shared Duration* from, Duration d)
    {
        if (d > *from)
        {
            d = *from;
        }

        //
        // this should not go negative
        //
        assert(d <= *from);
        Duration d1 = *from;
        *from = stripFracSeconds(d1 - d);

        return *from;
    }

    unittest
    {
        shared Duration d;

        d = dur!"hours"(2);
        assert(deductTime(&d, dur!"hours"(1)) == dur!"hours"(1));

        d = dur!"hours"(1);
        assert(deductTime(&d, dur!"hours"(2)) == Duration.zero);
        assert(deductTime(&d, Duration.zero) == Duration.zero);
    }

    @property public shared pure Interval!SysTime warmUpInterval()
    {
        return Interval!SysTime(startTime(), warmUpActiveTime() + warmUpInactiveTime());
    }

    @property public shared pure Duration stabilizationTime()
    {
        return m_stabilizationTime;
    }

    @property public shared pure Interval!SysTime stabilizationInterval()
    {
        return Interval!SysTime(warmUpInterval.end(), stabilizationTime());
    }

    @property public shared pure Duration cooldownTime()
    {
        return m_cooldownTime;
    }

    @property public shared pure string postedImageTweetId()
    {
        return m_postedImageTweetId;
    }

    @property public shared pure void postedImageTweetId(string value)
    {
        m_postedImageTweetId = value;
    }

    @property public shared pure string roundFolder()
    {
        return m_roundFolder;
    }

    //
    // cooldown time starts after the stabilization time ends
    //
    @property public shared pure Interval!SysTime cooldownInterval()
    {
        return Interval!SysTime(stabilizationInterval().end, cooldownTime());
    }

    private shared pure Duration secsSinceRoundStart(SysTime t)
    {
        return stripFracSeconds(t - startTime());
    }

    //
    // conveniently formatted string with round and time into round
    //
    public shared pure string getRoundAndSecOffset(SysTime t)
    {
        Duration secsIntoRound = secsSinceRoundStart(t);
        return format("r%04d-%05ds", number(), secsIntoRound.total!"seconds"());
    }

    public shared string formatForLogging()
    {
        string output;
        final switch (this.warmUpTimeHandling)
        {
            case WarmUpTimeHandling.ZeroInactive:
                output = format(
                    "warm-up active time (zero inactive): %s (%ss), stabilization time: %s, cooldown time: %s, prior cooldown time: %s",
                    this.warmUpActiveTime,
                    this.warmUpActiveTime.total!"seconds"(),
                    this.stabilizationTime,
                    this.cooldownTime,
                    this.priorCooldownTime);
            break;

            case WarmUpTimeHandling.EqualInactive:
                output = format(
                    "warm-up active time (equal inactive): %s (%ss), stabilization time: %s, cooldown time: %s, prior cooldown time: %s",
                    this.warmUpActiveTime,
                    this.warmUpActiveTime.total!"seconds"(),
                    this.stabilizationTime,
                    this.cooldownTime,
                    this.priorCooldownTime);
            break;

            case WarmUpTimeHandling.SurplusAfter:
            case WarmUpTimeHandling.SurplusBefore:
                output = format(
                    "warm-up active time: %s (%ss), warm-up inactive time: %s (%ss, %s%%), surplus at %s, stabilization time: %s, cooldown time: %s, prior cooldown time: %s",
                    this.warmUpActiveTime,
                    this.warmUpActiveTime.total!"seconds"(),
                    this.warmUpInactiveTime,
                    this.warmUpInactiveTime.total!"seconds"(),
                    this.warmUpInactiveTime.total!"seconds"() * 100 / this.warmUpActiveTime.total!"seconds"(),
                    this.warmUpTimeHandling == WarmUpTimeHandling.SurplusAfter ? "end" : "beginning",
                    this.stabilizationTime,
                    this.cooldownTime,
                    this.priorCooldownTime);
            break;
        }

        return output;
    }

    public shared JSONValue toJSON()
    {
        JSONValue root = JSONValue(
            [
                "round" : JSONValue(number()),
                "startTime" : JSONValue(startTime().toISOString()),
                "originalStartTime" : JSONValue(originalStartTime().toISOString()),
                "priorCooldownSeconds" : JSONValue(priorCooldownTime().total!"seconds"()),
                "warmUpActiveSeconds" : JSONValue(warmUpActiveTime().total!"seconds"()),
                "warmUpInactiveSeconds" : JSONValue(warmUpInactiveTime().total!"seconds"()),
                "warmUpTimeHandling" : JSONValue(warmUpTimeHandling()),
                "remainingWarmUpActiveSeconds" : JSONValue(remainingWarmUpActiveTime().total!"seconds"()),
                "remainingWarmUpInactiveSeconds" : JSONValue(remainingWarmUpInactiveTime().total!"seconds"()),
                "stabilizationSeconds" : JSONValue(stabilizationTime().total!"seconds"()),
                "cooldownSeconds" : JSONValue(cooldownTime().total!"seconds"()),
                "postedImageTweetId" : JSONValue(postedImageTweetId())
            ]);

        return root;
    }

    public static Round fromJSON(JSONValue root)
    {
        //
        // we know we'll never store something larger than a uint in here
        //
        uint round = cast(uint) root.object["round"].integer;

        SysTime startTime = SysTime.fromISOString(root.object["startTime"].str);
        SysTime originalStartTime = SysTime.fromISOString(root.object["originalStartTime"].str);
        Duration priorCooldownTime = dur!"seconds"(root.object["priorCooldownSeconds"].integer);
        Duration warmUpActiveTime = dur!"seconds"(root.object["warmUpActiveSeconds"].integer);
        Duration warmUpInactiveTime = dur!"seconds"(root.object["warmUpInactiveSeconds"].integer);
        WarmUpTimeHandling warmUpTimeHandling = cast(WarmUpTimeHandling) root.object["warmUpTimeHandling"].integer;
        Duration remainingWarmUpActiveTime = dur!"seconds"(root.object["remainingWarmUpActiveSeconds"].integer);
        Duration remainingWarmUpInactiveTime = dur!"seconds"(root.object["remainingWarmUpInactiveSeconds"].integer);
        Duration stabilizationTime = dur!"seconds"(root.object["stabilizationSeconds"].integer);
        Duration cooldownTime = dur!"seconds"(root.object["cooldownSeconds"].integer);
        string postedImageTweetId = null;
        JSONValue* jvPostedImageTweetId = `postedImageTweetId` in root.object;
        if (jvPostedImageTweetId !is null)
        {
            postedImageTweetId = jvPostedImageTweetId.str;
        }

        return new Round(
                       round,
                       startTime,
                       originalStartTime,
                       priorCooldownTime,
                       warmUpActiveTime,
                       warmUpInactiveTime,
                       warmUpTimeHandling,
                       remainingWarmUpActiveTime,
                       remainingWarmUpInactiveTime,
                       stabilizationTime,
                       cooldownTime,
                       postedImageTweetId);
    }
}

class TwitterInfo
{
    AccessToken m_token;

    public this(
        string apiKey,
        string apiSecret,
        string accountKey,
        string accountSecret)
    {
        m_token.consumer.key = apiKey;
        m_token.consumer.secret = apiSecret;
        m_token.key = accountKey;
        m_token.secret = accountSecret;
    }

    @property public pure AccessToken accessToken()
    {
        return m_token;
    }

    public JSONValue toJSON()
    {
        JSONValue auth = JSONValue(
            [
                "apiKey": JSONValue(accessToken().consumer.key),
                "apiSecret": JSONValue(accessToken.consumer.secret),
                "accountKey": JSONValue(accessToken.key),
                "accountSecret": JSONValue(accessToken.secret),
            ]);

        JSONValue root = JSONValue(
            [
                "auth" : auth,
            ]);

        return root;
    }

    public static TwitterInfo fromJSON(JSONValue root)
    {
        JSONValue auth = root.object["auth"];

        return new TwitterInfo(
            auth.object["apiKey"].str,
            auth.object["apiSecret"].str,
            auth.object["accountKey"].str,
            auth.object["accountSecret"].str);
    }
}

ulong[] ulongArrayFromJSON(JSONValue root, ulong exactLength)
{
    if (root.type != JSON_TYPE.ARRAY)
    {
        throw new Exception("invalid ulong array in JSON -- needs to be array");
    }

    JSONValue[] arrayContents = root.array;
    if (arrayContents.length != exactLength)
    {
        throw new Exception(format("invalid ulong array in JSON -- needs to have exactly %u elements, not %u", exactLength, arrayContents.length));
    }

    ulong[] arr;
    arr.length = exactLength;

    for (int i = 0; i < exactLength; i++)
    {
        if (arrayContents[i].integer < 0)
        {
            throw new Exception(format("invalid ulong array in JSON -- cannot have negative value in element %u", i));
        }

        arr[i] = arrayContents[i].integer;
    }

    return arr;
}

public JSONValue ulongArrayToJSON(ulong[] arr)
{
    JSONValue root;
    root.array = array(arr.map!(x => JSONValue(x))());
    return root;
}

struct NumberRange
{
    ulong min;
    ulong max;

    public ulong random()
    {
        return uniform(this.min, this.max);
    }

    public static NumberRange fromJSON(JSONValue root)
    {
        ulong[] arr = ulongArrayFromJSON(root, 2);

        NumberRange nr;
        nr.min = arr[0];
        nr.max = arr[1];
        return nr;
    }

    public JSONValue toJSON()
    {
        return ulongArrayToJSON([this.min, this.max]);
    }
}

struct DurationRange
{
    Duration min;
    Duration max;

    public Duration randomDuration(string unitGranularity)()
    {
        return dur!unitGranularity(uniform(
            this.min.total!unitGranularity(),
            this.max.total!unitGranularity()));
    }

    public static DurationRange fromJSON(string units)(JSONValue root)
    {
        NumberRange nr = NumberRange.fromJSON(root);

        DurationRange dr;
        dr.min = dur!units(nr.min);
        dr.max = dur!units(nr.max);
        return dr;
    }

    public JSONValue toJSON(string units)()
    {
        NumberRange nr;
        nr.min = this.min.total!units();
        nr.max = this.max.total!units();
        return nr.toJSON();
    }
}

struct TuningConfig
{
    DurationRange rangeCooldownTime;
    Duration stabilizationTime;
    DurationRange rangeWarmUpActiveTimeWithZeroInactive;
    DurationRange rangeWarmUpActiveTimeWithEqualInactive;
    DurationRange rangeWarmUpActiveTimeWithSurplusAfter;
    NumberRange rangeWarmUpInactivePercentOfActiveSurplusAfter;
    DurationRange rangeWarmUpActiveTimeWithSurplusBefore;
    NumberRange rangeWarmUpInactivePercentOfActiveSurplusBefore;
    DurationRange rangeActiveCycleTime;
    ulong[] choicesWarmUpTimeHandling;
    string ffmpegPath;
    ulong videoBitrate;

    public static TuningConfig fromJSON(JSONValue root)
    {
        TuningConfig ti;

        ti.rangeCooldownTime = DurationRange.fromJSON!"minutes"(root.object["rangeOfCooldownMinutes"]);

        ti.stabilizationTime = dur!"minutes"(root.object["stabilizationMinutes"].integer);

        ti.rangeWarmUpActiveTimeWithZeroInactive = DurationRange.fromJSON!"seconds"(root.object["rangeOfWarmUpActiveSecondsZeroInactive"]);

        ti.rangeWarmUpActiveTimeWithEqualInactive = DurationRange.fromJSON!"seconds"(root.object["rangeOfWarmUpActiveSecondsEqualInactive"]);

        ti.rangeWarmUpActiveTimeWithSurplusAfter = DurationRange.fromJSON!"seconds"(root.object["rangeOfWarmUpActiveSecondsSurplusAfter"]);
        ti.rangeWarmUpInactivePercentOfActiveSurplusAfter = NumberRange.fromJSON(root.object["rangeOfWarmUpInactivePercentOfActiveSurplusAfter"]);

        ti.rangeWarmUpActiveTimeWithSurplusBefore = DurationRange.fromJSON!"seconds"(root.object["rangeOfWarmUpActiveSecondsSurplusBefore"]);
        ti.rangeWarmUpInactivePercentOfActiveSurplusBefore = NumberRange.fromJSON(root.object["rangeOfWarmUpInactivePercentOfActiveSurplusBefore"]);

        ti.rangeActiveCycleTime = DurationRange.fromJSON!"seconds"(root.object["rangeActiveCycleTimeSeconds"]);

        ti.choicesWarmUpTimeHandling = ulongArrayFromJSON(root.object["choicesWarmUpTimeHandling"], WarmUpTimeHandling.max+1);

        ti.ffmpegPath = root.object[`ffmpegPath`].str;
        ti.videoBitrate = root.object[`videoBitrate`].integer;

        return ti;
    }

    @property public pure bool isVideoEnabled()
    {
        return videoBitrate != 0;
    }
}

//
// encompasses the web cam to take photos of the lava lamp. actually, it's
// pretty much just a generic webcam. it calls out to takephoto.exe to do the
// heavy lifting
//
class LavaCam
{
    private int m_camDevice;
    private string m_takePhotoPath;

    public this(
        int camDevice,
        string takePhotoPath)
    {
        m_camDevice = camDevice;
        m_takePhotoPath = takePhotoPath;

        if (!exists(m_takePhotoPath))
        {
            throw new Exception(format("cannot find takephoto.exe at %s", m_takePhotoPath));
        }
    }

    public shared const void takePhoto(string outputPath, bool showLog)
    {
        if (showLog)
        {
            log("Taking photo and saving to %s", outputPath);
        }

        string takePhotoCommand = format(
                                      "%s %s -o %s",
                                      m_takePhotoPath,
                                      (m_camDevice >= 0 ? format("-d %d", m_camDevice) : ""),
                                      outputPath);

        if (showLog)
        {
            log(takePhotoCommand);
        }

        if (g_forReals)
        {
            int status = executeShellWithWait(takePhotoCommand, dur!`minutes`(1));
            if (status != 0)
            {
                throw new TakePhotoException(format("failed takephoto: %d", status), `unknown`);
            }
        }
        else
        {
            //
            // Try copying the next test image to the round folder in place of
            // a real photo from a camera. If we fail to copy it, assume we ran
            // out of test photos and try again, starting from test photo #1.
            //
            for (uint i = 0; i < 2; i++)
            {
                string testPhotoPath = buildPath(g_rootPath, `test`, format(`%u.jpg`, g_testPhotoNum));
                try
                {
                    std.file.copy(testPhotoPath, outputPath);
                    g_testPhotoNum++;
                    break;
                }
                catch (Throwable ex)
                {
                    g_testPhotoNum = 1;
                }
            }
        }
    }

    //
    // uses the current round to construct the path for the default photos
    // storage folder
    //
    public shared const string takePhotoToPhotosFolder(string fileSuffix = "", bool showLog = false)
    {
        SysTime currTime = g_clock.currTime;
        string photoPath = buildPath(g_currentRound.roundFolder(), format("%s_%s%s.jpg", currTime.toISOString(), g_currentRound.getRoundAndSecOffset(currTime), fileSuffix));
        takePhoto(photoPath, showLog);
        return photoPath;
    }

    public static int enumerateCameras(string takePhotoPath)
    {
        if (!exists(takePhotoPath))
        {
            throw new Exception(format("cannot find takephoto.exe at %s", takePhotoPath));
        }

        string takePhotoCommand = format("%s -enum", takePhotoPath);
        auto result = executeShell(takePhotoCommand);

        write(result.output);

        return result.status;
    }
}

class TakePhotoException : Exception
{
    private string m_output;

    public this(string msg, string output)
    {
        super(msg);
        m_output = output;
    }

    @property pure string output()
    {
        return m_output;
    }
}
