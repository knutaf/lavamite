import std.stdio;
import std.process;
import std.path;
import std.json;
import std.file;
import std.string;

import graphite.twitter;

string g_rootPath;
string g_configFile;
TwitterInfo g_twitterInfo;

void log(Args...)(string fmt, Args args)
{
    writeln(format(fmt, args));
}

void processConfigFile()
{
    TwitterInfo twitterInfo;

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
    }
    else
    {
        throw new Exception(format("Missing JSON config file %s. Must contain Twitter info and tuning config.", g_configFile));
    }

    g_twitterInfo = twitterInfo;
}

void tweetText(string textToTweet)
{
    string[string] parms;
    parms["status"] = textToTweet;

    log("Tweeting \"%s\"", textToTweet);

    Twitter.statuses.update(g_twitterInfo.accessToken, parms);
}

void tweetTextAndPhoto(string textToTweet, string photoPath, string mimeType, Twitter.MediaCategory mediaCategory)
{
    string[string] parms;
    parms["status"] = textToTweet;

    log("Tweeting \"%s\" with image %s", textToTweet, photoPath);

    Twitter.statuses.updateWithMedia(g_twitterInfo.accessToken, photoPath, mimeType, mediaCategory, parms);
    //writefln("twitter output: %s", Twitter.media.upload(g_twitterInfo.accessToken, photoPath));
}

void usage()
{
    writefln("tweetit [-img image_path | -gif gif_path | -vid vid_path] \"tweet text\"");
}

int main(string[] args)
{
    string textToTweet = null;
    string imagePath = null;
    string mimeType = null;
    Twitter.MediaCategory mediaCategory = Twitter.MediaCategory.TweetImage;
    string proxy = null;
    uint i;
    uint lastUsedArg = 0;
    for (i = 1; i < args.length; i++)
    {
        if (cmp(args[i], "-img") == 0)
        {
            i++;
            if (i < args.length)
            {
                imagePath = args[i];
                mediaCategory = Twitter.MediaCategory.TweetImage;
                lastUsedArg = i;
            }
            else
            {
                usage();
                return 1;
            }
        }
        else if (cmp(args[i], "-gif") == 0)
        {
            i++;
            if (i < args.length)
            {
                imagePath = args[i];
                mediaCategory = Twitter.MediaCategory.TweetGif;
                lastUsedArg = i;
            }
            else
            {
                usage();
                return 1;
            }
        }
        else if (cmp(args[i], "-vid") == 0)
        {
            i++;
            if (i < args.length)
            {
                imagePath = args[i];
                mediaCategory = Twitter.MediaCategory.TweetVideo;
                lastUsedArg = i;
            }
            else
            {
                usage();
                return 1;
            }
        }
        else if (cmp(args[i], "-mime") == 0)
        {
            i++;
            if (i < args.length)
            {
                mimeType = args[i];
                lastUsedArg = i;
            }
            else
            {
                usage();
                return 1;
            }
        }
        else if (cmp(args[i], "-proxy") == 0)
        {
            i++;
            if (i < args.length)
            {
                proxy = args[i];
                lastUsedArg = i;
            }
            else
            {
                usage();
                return 1;
            }
        }
    }

    lastUsedArg++;
    if (lastUsedArg < args.length)
    {
        textToTweet = args[lastUsedArg];
    }
    else
    {
        usage();
        return 1;
    }

    Twitter.proxy = proxy;

    if (textToTweet !is null)
    {
        g_rootPath = dirName(thisExePath());
        g_configFile = buildPath(g_rootPath, "tweetit.config");
        processConfigFile();
        log("twitter info: %s", g_twitterInfo.toJSON());

        if (imagePath !is null)
        {
            tweetTextAndPhoto(textToTweet, imagePath, mimeType, mediaCategory);
        }
        else
        {
            tweetText(textToTweet);
        }
    }

    return 0;
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
