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

import core.sys.windows.windows;
import windows_serial;

import graphite.twitter;

shared string g_rootPath;
shared PrivateClock g_clock;
string g_configFile;
shared bool g_forReals;
Tid g_loggingThread;

shared Round g_currentRound;
TwitterInfo g_twitterInfo;

immutable uint MINS_PER_HOUR = 60;

enum ActiveTimeSurplusHandling
{
    AtEnd = 0,
    AtBeginning = 1,
}

pure Duration stripFracSeconds(Duration d)
{
    return d - dur!"nsecs"(d.split!("seconds", "nsecs").nsecs);
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

string formatDurationToHoursMins(Duration d)
{
    return format("%d:%02d", d.total!"hours"(), d.split!("hours", "minutes").minutes);
}

string formatRoundFolder(shared Round r)
{
    return buildPath(g_rootPath, format("round_%04d_%s", r.number, formatTimeToSeconds(r.originalStartTime)));
}

void ensureFolder(string folderPath)
{
    if (!exists(folderPath))
    {
        mkdir(folderPath);
    }
}

void log(string msg)
{
    send(g_loggingThread, msg);
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
            // this can be called before the first round has been set. in
            // that case, log a format that doesn't include round info. if
            // the current round is set, check if it is a new round, and if
            // so, open a log file in the new folder.
            //
            // only write to log file if the current round is set. write out
            // to stdout always.
            //
            if (g_currentRound !is null)
            {
                string newLogFolder = formatRoundFolder(g_currentRound);
                if (logFolder is null || (cmp(newLogFolder, logFolder) != 0))
                {
                    logFolder = newLogFolder;
                    logFile = File(buildPath(logFolder, "lavamite.log"), "a");
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
// with tuning. it only takes photos while the lamp is on, because who cares
// what it looks like when it's off?
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
                    log(format("failed to take photo: %s\n%s", ex, ex.output));
                }
                catch (Throwable ex)
                {
                    log(format("exception in photo thread: %s", ex));
                }

                //
                // wait a while until taking the next picture
                //
                receiveTimeout(dur!"minutes"(1), &setLampState);
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
        else
        {
            usage(format("unknown argument %s", args[i]));
            return 1;
        }
    }

    shared LavaCam camera = cast(shared LavaCam)(new LavaCam(camDevice, takePhotoPath));

    g_configFile = buildPath(g_rootPath, (g_forReals ? "lavamite_config.json" : "lavamite_config_dry.json"));

    processConfigFile();

    //
    // at this point, g_currentRound is set
    //

    DWORD baudRate = CBR_9600;
    ControllablePowerSwitch powerSwitch = new ControllablePowerSwitch(comPort, baudRate);

    log(format("Attached to power switch on %s at %d baud", comPort, baudRate));

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
            //    processConfigFile, we adjust the last round info so that
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
                // time, warmup time, and total time till stabilization.
                // these parameters have been deduced empirically
                //
                // cooldown time:
                // select a fairly long cooldown time. for now we actually
                // use a constant cooldown time, since varied cooldown times
                // don't appear to produce more interesting shapes
                //
                // warm up time:
                // choose based on the last round's (albeit static) cooldown
                // time; the longer the lamp had to cool down, the more time
                // it will take to warm up. but after a certain amount of
                // cooldown time, it's effectively the same, so cap it.
                //
                // time to stabilization (aka steady state):
                // take a while to stabilize the lamp till it's bubbling at
                // steady state.
                //
                Duration cooldownTime = dur!"minutes"(uniform(4 * MINS_PER_HOUR, 5 * MINS_PER_HOUR));

                Duration cappedLastCooldownTime = min(g_currentRound.cooldownTime, dur!"hours"(4));

                //
                // The time to get to steady state, which is known to get the
                // lamp bubbling nicely
                //
                Duration stabilizationTime;

                //
                // in cooler times, 40-50% of 4 hours works. in warmer times,
                // 30-40% of 4 hours seems to work
                //
                // TODO: experimenting with 252-271% of 4 hours, using inactive
                // warmup time too
                //
                ulong minWarmUpSeconds = ((252 * cappedLastCooldownTime) / 100).total!"seconds"();
                ulong maxWarmUpSeconds = ((271 * cappedLastCooldownTime) / 100).total!"seconds"();
                Duration warmUpActiveTime = dur!"seconds"(uniform(minWarmUpSeconds, maxWarmUpSeconds));
                Duration warmUpInactiveTime;
                ActiveTimeSurplusHandling activeTimeSurplusHandling = ActiveTimeSurplusHandling.AtEnd;

                //
                // choose whether to flicker the lamp on and off during the
                // warm-up time
                //
                // TODO: for now we will do this all the time, to test it out
                //
                //if (dice(50, 50) == 0)
                if (dice(0, 100) == 0)
                {
                    warmUpInactiveTime = Duration.zero;

                    //
                    // 3 hours is enough time to get the lamp stable, but we
                    // have been continuously active for a while, so subtract
                    // out that time
                    //
                    stabilizationTime = dur!"hours"(3) - warmUpActiveTime;
                }
                else
                {
                    //
                    // choose whether there is the same amount of inactive time
                    // as active time, or if there is more active time. we will
                    // never choose less active time, because the lamp needs a
                    // decent amount of heat to produce formations
                    //
                    // TODO: for now always choose to have equal active and
                    // inactive time
                    //
                    if (dice(100, 0) == 0)
                    {
                        //
                        // same active time as inactive time
                        //

                        warmUpInactiveTime = warmUpActiveTime;

                        //
                        // even though the lamp may have been intermittently
                        // active for several hours, the interleaved cooling
                        // periods mess with this. stabilization really needs
                        // a continuous period of active time. 90 minutes is
                        // pretty good
                        //
                        stabilizationTime = dur!"minutes"(90);
                    }
                    else
                    {
                        //
                        // more active time than inactive time
                        //

                        ulong warmUpActiveSeconds = warmUpActiveTime.total!"seconds"();

                        //
                        // inactive time is 25-50% of active time
                        //
                        warmUpInactiveTime = dur!"seconds"(uniform((25 * warmUpActiveSeconds) / 100, (50 * warmUpActiveSeconds) / 100));

                        //
                        // since there is more active time than inactive,
                        // choose what to do with the surplus active time.
                        // either do it all at the beginning or all at the end
                        //
                        // TODO: for now, we put it all at the end
                        activeTimeSurplusHandling = cast(ActiveTimeSurplusHandling) dice(100, 0);
                    }

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
                        activeTimeSurplusHandling,
                        warmUpActiveTime,            // remaining active
                        warmUpInactiveTime,          // remaining inactive
                        stabilizationTime,           // stabilization time
                        cooldownTime));              // cooldown time

                log(format(
                    "********* STARTING ROUND: warm-up active time: %s, warm-up inactive time: %s, surplus: %s, stabilization time: %s, cooldown time: %s, prior cooldown time: %s",
                    g_currentRound.warmUpActiveTime,
                    g_currentRound.warmUpInactiveTime,
                    g_currentRound.activeTimeSurplusHandling == ActiveTimeSurplusHandling.AtEnd ? "at end" : "at beginning",
                    g_currentRound.stabilizationTime,
                    g_currentRound.cooldownTime,
                    g_currentRound.priorCooldownTime));
            }
            else
            {
                log(format(
                    "********* CONTINUING ROUND, %s in: warm-up active time: %s, warm-up inactive time: %s, surplus: %s, stabilization time: %s, cooldown time: %s, prior cooldown time: %s",
                    stripFracSeconds(g_clock.currTime - g_currentRound.startTime),
                    g_currentRound.warmUpActiveTime,
                    g_currentRound.warmUpInactiveTime,
                    g_currentRound.activeTimeSurplusHandling == ActiveTimeSurplusHandling.AtEnd ? "at end" : "at beginning",
                    g_currentRound.stabilizationTime,
                    g_currentRound.cooldownTime,
                    g_currentRound.priorCooldownTime));
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
                if (g_currentRound.activeTimeSurplusHandling == ActiveTimeSurplusHandling.AtBeginning && g_currentRound.remainingWarmUpActiveTime > g_currentRound.warmUpInactiveTime)
                {
                    //
                    // consume enough to bring the remaining active time
                    // down to the same amount of inactive time
                    //
                    Duration activeTimeAtBeginningDuration = g_currentRound.remainingWarmUpActiveTime - g_currentRound.warmUpInactiveTime;

                    log(format("consuming surplus active time at the beginning: %s", activeTimeAtBeginningDuration));

                    powerSwitch.turnOnPower();
                    auto sleepResult = sleepHowLongWithExitCheck(activeTimeAtBeginningDuration);
                    g_currentRound.deductRemainingWarmUpActiveTime(sleepResult.timeSlept);

                    if (sleepResult.isExitRequested)
                    {
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
                    // if there is significant inactive time left to be
                    // consumed, do one period of active time followed by one
                    // period of inactive time
                    //
                    Duration minCycleTime = dur!"minutes"(1);
                    Duration maxCycleTime = dur!"minutes"(10);
                    if (g_currentRound.remainingWarmUpInactiveTime > minCycleTime)
                    {
                        Duration thisCycleActiveTime = min(dur!"seconds"(uniform(minCycleTime.total!"seconds"(), maxCycleTime.total!"seconds"())), g_currentRound.remainingWarmUpActiveTime);
                        log(format("active cycle time = %s. remaining active: %s, remaining inactive: %s", thisCycleActiveTime, g_currentRound.remainingWarmUpActiveTime, g_currentRound.remainingWarmUpInactiveTime));

                        auto sleepResult = sleepHowLongWithExitCheck(thisCycleActiveTime);
                        g_currentRound.deductRemainingWarmUpActiveTime(sleepResult.timeSlept);

                        isExitRequested = sleepResult.isExitRequested;
                        if (isExitRequested)
                        {
                            break;
                        }

                        Duration thisCycleInactiveTime = min(dur!"seconds"(uniform(minCycleTime.total!"seconds"(), maxCycleTime.total!"seconds"())), g_currentRound.remainingWarmUpInactiveTime);

                        powerSwitch.turnOffPower();
                        log(format("inactive cycle time = %s. remaining active: %s, remaining inactive: %s", thisCycleInactiveTime, g_currentRound.remainingWarmUpActiveTime, g_currentRound.remainingWarmUpInactiveTime));

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
                        log(format("Leaving on to consume all warmup active time: %s", g_currentRound.remainingWarmUpActiveTime));
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
                    log(format("Exiting during warmup. Remaining active time: %s, inactive time: %s", g_currentRound.remainingWarmUpActiveTime, g_currentRound.remainingWarmUpInactiveTime));
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
                log(format("Leaving on for remaining time to stabilization, %s", stripFracSeconds(remainingStabilizationTime)));

                if (sleepWithExitCheck(remainingStabilizationTime))
                {
                    break;
                }
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

                Duration remainingCooldownTime = g_currentRound.cooldownInterval.end - g_clock.currTime + dur!"seconds"(5);
                log(format("Cooling down for %s until next session", stripFracSeconds(remainingCooldownTime)));
                if (sleepWithExitCheck(remainingCooldownTime))
                {
                    break;
                }
            }

            assert(inSomePhase);
        }
        catch (Throwable ex)
        {
            log(format("exception. will continue with next round. %s", ex));
        }
    } while (true);

    writeConfigFile();

    log("Exiting...");
    powerSwitch.turnOffPower();

    return 0;
}

//
// The config file has several settings that we use:
//
// twitterInfo: required. contains the authentication information for posting
// to twitter
//
// lastRoundInfo: optional. contains the information about the last round
// that we did, so we can pick up where we left off
//
// lastActionTime: optional. along with last round info, lets us know how far
// into the last round the program was running, to let us pick up where we
// left off
//
void processConfigFile()
{
    Round r;
    TwitterInfo ti;
    SysTime lastActionTime = g_clock.currTime;
    bool haveAllLastActionTimeInfo = true;

    if (exists(g_configFile))
    {
        JSONValue root;

        try
        {
            root = parseJSON(readText(g_configFile));
        }
        catch (Throwable ex)
        {
            log(format("Malfomed JSON in config file %s. Must minimally contain Twitter info.", g_configFile));
            throw ex;
        }

        try
        {
            JSONValue* lastRoundInfo = "lastRoundInfo" in root.object;
            if (lastRoundInfo !is null)
            {
                r = Round.fromJSON(*lastRoundInfo);
            }
            else
            {
                r = new Round(
                        0,                    // round number
                        g_clock.currTime,     // start time
                        g_clock.currTime,     // original start time
                        Duration.zero(),      // prior cooldown time
                        dur!"seconds"(1),     // warmup active time
                        Duration.zero(),      // warmup inactive time
                        ActiveTimeSurplusHandling.AtEnd,
                        dur!"seconds"(1),     // remaining warmup active time
                        Duration.zero(),      // remaining warmup inactive
                        dur!"seconds"(1),     // stabilization time
                        dur!"hours"(4));      // cooldown time

                haveAllLastActionTimeInfo = false;
            }
        }
        catch (Throwable ex)
        {
            log(format("Well-formed JSON file %s with incorrect last round info.", g_configFile));
            throw ex;
        }

        try
        {
            JSONValue twitterInfo = root.object["twitterInfo"];
            ti = TwitterInfo.fromJSON(twitterInfo);
        }
        catch (Throwable ex)
        {
            log(format("Well-formed JSON file %s that does not contain Twitter info. Must fix.", g_configFile));
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
                haveAllLastActionTimeInfo = false;
            }
        }
        catch (Throwable ex)
        {
            log(format("Well-formed JSON file %s with malformed lastActionTime (should be ISO string). Must fix.", g_configFile));
            throw ex;
        }
    }
    else
    {
        throw new Exception(format("Missing JSON config file %s. Must minimally contain Twitter info.", g_configFile));
    }

    g_twitterInfo = ti;

    shared Round rs = cast(shared Round)r;

    //
    // if we're missing any of the information to calculate the correct
    // offset into the last round, we put ourselves after the end of the last
    // round
    //
    if (!haveAllLastActionTimeInfo)
    {
        lastActionTime = rs.wholeRoundInterval.end + dur!"seconds"(1);
    }

    //
    // this is really important. shift the round that we loaded from file
    // to be offset from the current time. We calculate how far we made it
    // into the last round, then adjust the startTime of the round to
    // position the current time at that point.
    //
    r = new Round(
            rs.number,
            g_clock.currTime - (lastActionTime - rs.startTime),
            rs.startTime,
            rs.priorCooldownTime,
            rs.warmUpActiveTime,
            rs.warmUpInactiveTime,
            rs.activeTimeSurplusHandling,
            rs.remainingWarmUpActiveTime,
            rs.remainingWarmUpInactiveTime,
            rs.stabilizationTime,
            rs.cooldownTime);

    setCurrentRound(r);
}

void writeConfigFile()
{
    JSONValue root = JSONValue(
        [
            "lastRoundInfo" : g_currentRound.toJSON(),
            "twitterInfo": g_twitterInfo.toJSON(),
            "lastActionTime": JSONValue(g_clock.currTime.toISOString()),
        ]);

    File outfile = File(g_configFile, "w");
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
    ensureFolder(formatRoundFolder(rs));

    g_currentRound = rs;
    writeConfigFile();
}

void tweetTextAndPhoto(string textToTweet, string photoPath)
{
    string[string] parms;
    parms["status"] = textToTweet;

    log(format("Tweeting \"%s\" with image %s", textToTweet, photoPath));
    //Twitter.statuses.update(g_twitterInfo.accessToken, parms);

    if (g_forReals)
    {
        // TODO: re-enable when live
        //Twitter.statuses.updateWithMedia(g_twitterInfo.accessToken, [photoPath], parms);
    }
}

void takeAndPostPhoto(shared LavaCam camera)
{
    immutable uint numPhotoTries = 5;

    string photoPath;
    foreach (uint i; 1 .. numPhotoTries+1)
    {
        try
        {
            photoPath = camera.takePhotoToPhotosFolder("-posted", true);
            break;
        }
        catch (Throwable ex)
        {
            log(format("failure number %d to take photo: %s", i, ex));
        }
    }

    tweetTextAndPhoto(
        format(
            "Round %d. Prior cooldown time: %s. Warm-up time: %s.",
            g_currentRound.number,
            formatDurationToHoursMins(g_currentRound.priorCooldownTime),
            formatDurationToHoursMins(g_currentRound.warmUpActiveTime)),
        photoPath);
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

        log(format("Waiting for %s for microcontroller to initialize", initTime));
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

        //log(format("Previous baud: %d, byteSize: %d, parity: %d, stopbits: %d", dcb.m_BaudRate, dcb.ByteSize, dcb.Parity, dcb.StopBits));

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
    private ActiveTimeSurplusHandling m_activeTimeSurplusHandling;
    private Duration m_remainingWarmUpActiveTime;
    private Duration m_remainingWarmUpInactiveTime;
    private Duration m_stabilizationTime;
    private Duration m_cooldownTime;

    public this(
        uint number,
        SysTime startTime,
        SysTime originalStartTime,
        Duration priorCooldownTime,
        Duration warmUpActiveTime,
        Duration warmUpInactiveTime,
        ActiveTimeSurplusHandling activeTimeSurplusHandling,
        Duration remainingWarmUpActiveTime,
        Duration remainingWarmUpInactiveTime,
        Duration stabilizationTime,
        Duration cooldownTime)
    {
        this.m_number = number;
        m_startTime = startTime.stdTime;
        m_originalStartTime = originalStartTime.stdTime;

        m_priorCooldownTime = priorCooldownTime;
        m_warmUpActiveTime = warmUpActiveTime;
        m_warmUpInactiveTime = warmUpInactiveTime;
        m_activeTimeSurplusHandling = activeTimeSurplusHandling;
        m_remainingWarmUpActiveTime = remainingWarmUpActiveTime;
        m_remainingWarmUpInactiveTime = remainingWarmUpInactiveTime;
        m_stabilizationTime = stabilizationTime;
        m_cooldownTime = cooldownTime;
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

    @property public shared pure ActiveTimeSurplusHandling activeTimeSurplusHandling()
    {
        return m_activeTimeSurplusHandling;
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
                "activeTimeSurplusHandling" : JSONValue(activeTimeSurplusHandling()),
                "remainingWarmUpActiveSeconds" : JSONValue(remainingWarmUpActiveTime().total!"seconds"()),
                "remainingWarmUpInactiveSeconds" : JSONValue(remainingWarmUpInactiveTime().total!"seconds"()),
                "stabilizationSeconds" : JSONValue(stabilizationTime().total!"seconds"()),
                "cooldownSeconds" : JSONValue(cooldownTime().total!"seconds"())
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
        ActiveTimeSurplusHandling activeTimeSurplusHandling = cast(ActiveTimeSurplusHandling) root.object["activeTimeSurplusHandling"].integer;
        Duration remainingWarmUpActiveTime = dur!"seconds"(root.object["remainingWarmUpActiveSeconds"].integer);
        Duration remainingWarmUpInactiveTime = dur!"seconds"(root.object["remainingWarmUpInactiveSeconds"].integer);
        Duration stabilizationTime = dur!"seconds"(root.object["stabilizationSeconds"].integer);
        Duration cooldownTime = dur!"seconds"(root.object["cooldownSeconds"].integer);

        return new Round(
                       round,
                       startTime,
                       originalStartTime,
                       priorCooldownTime,
                       warmUpActiveTime,
                       warmUpInactiveTime,
                       activeTimeSurplusHandling,
                       remainingWarmUpActiveTime,
                       remainingWarmUpInactiveTime,
                       stabilizationTime,
                       cooldownTime);
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
            log(format("Taking photo and saving to %s", outputPath));
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
            auto result = executeShell(takePhotoCommand);
            if (result.status != 0)
            {
                throw new TakePhotoException(format("failed takephoto: %d", result.status), result.output);
            }
        }
        else
        {
             //
             // in dry run mode, create a file so we can see that the
             // filename and path is correct, but don't put anything in it,
             // and don't call it a .jpg, lest it confuse the OS or something
             //
             File fakePhoto = File(format("%s_fake", outputPath), "w");
        }
    }

    //
    // uses the current round to construct the path for the default photos
    // storage folder
    //
    public shared const string takePhotoToPhotosFolder(string fileSuffix = "", bool showLog = false)
    {
        SysTime currTime = g_clock.currTime;
        string photoPath = buildPath(formatRoundFolder(g_currentRound), format("%s_%s%s.jpg", currTime.toISOString(), g_currentRound.getRoundAndSecOffset(currTime), fileSuffix));
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
