#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <shavit/core>
#undef REQUIRE_PLUGIN
#include <shavit/checkpoints>

// Progress Log: a practice diary per map. Entries are "<from> to <to>": run times (1:00), Start / End, or the
// name of a spot (a name with a time, e.g. "End slope" = 3:45). Kept per day (the day rolls over at
// sm_prog_daystart). "End" is also a spot: your estimated finish time, the 100 % that percentages show against.
//   !prog                    the Progress Log window (CS:TV client) or the menu
//   !prog 2:24 to 4:02       log an entry right away (or !prog 224 to 402)
//   !progsave (bind it)      log the attempt you just played: from where it began (Start, or your time at the
//                            checkpoint you loaded) to where you failed (the last teleport / death in the last
//                            20 s, else where you are). Press again before the next attempt: updates it.
// The window: the client answers `prog_ui hello 2`, gets this map's entries in the background (a few lines per
// tick) and every change after that, and sends `sm_progui ...` back (see cstv_prog.inc). !progmenu = the menu.
//
// 2.0: run times only (1.x had map progress from the record replay: unreliable); spots = name + time.
// 2.1: spots are a time range (you reach a place at different times): "End slope" = 3:40-3:55; entries named
//      after a spot take its middle. "Furthest" in the menus counts runs from Start only. prog_bin (5-60 s): the
//      window's fail ranges for its stats and graph.
// 2.2: digits alone read like a timer: "224 to 402" = 2:24 to 4:02 (was seconds: 3:44 to 6:42); "224s" = seconds.

#define PLUGIN_VERSION "2.2"
#define PREFIX " \x04[Prog]\x01"
#define MAX_TEXT 32
#define FAIL_WINDOW 20.0
#define OUT_PER_TICK 20

public Plugin myinfo =
{
    name = "Progress Log",
    author = "brylin",
    description = "Practice diary: from / to entries per day (!prog, !progsave)",
    version = PLUGIN_VERSION,
    url = ""
};

Database g_hDB;
ConVar g_cvDayStart;
Cookie g_hAutoFinishCookie;
Cookie g_hSaveAtCookie;
Cookie g_hBinCookie;

// the attempt being played
bool g_bAttempt[MAXPLAYERS + 1];
char g_sFrom[MAXPLAYERS + 1][MAX_TEXT];
float g_fFromTime[MAXPLAYERS + 1];
float g_fAttemptStart[MAXPLAYERS + 1];	// game time
int g_iAttemptEntry[MAXPLAYERS + 1];	// entry already saved for this attempt (progsave again updates it)
// the last fail: a teleport (the map sending you back) or a death
float g_fFailTime[MAXPLAYERS + 1];		// your run time just before it
float g_fFailAt[MAXPLAYERS + 1];		// game time, 0 none
float g_fLastPos[MAXPLAYERS + 1][3];
float g_fLastTime[MAXPLAYERS + 1];
bool g_bHavePos[MAXPLAYERS + 1];

// the CS:TV client's window
bool g_bUI[MAXPLAYERS + 1];
bool g_bViewing[MAXPLAYERS + 1];
ArrayList g_hOut[MAXPLAYERS + 1];

// the menu (clients without the window): waiting for something typed in chat
enum
{
    INPUT_NONE,
    INPUT_ADD,
    INPUT_EDIT_FROM,
    INPUT_EDIT_TO,
    INPUT_SPOT
}
int g_iInput[MAXPLAYERS + 1];
int g_iInputEntry[MAXPLAYERS + 1];
float g_fInputTime[MAXPLAYERS + 1];
char g_sViewDay[MAXPLAYERS + 1][16];

public void OnPluginStart()
{
    g_cvDayStart = CreateConVar("sm_prog_daystart", "5", "Hour the Progress Log day starts (0-23): a late session counts for the day it began", 0, true, 0.0, true, 23.0);
    AutoExecConfig(true, "progresslog");
    g_hAutoFinishCookie = new Cookie("prog_autofinish", "Progress Log: log finished runs automatically (1/0)", CookieAccess_Protected);
    g_hSaveAtCookie = new Cookie("prog_saveat", "Progress Log: !progsave ends at the last fail (0) or where you are (1)", CookieAccess_Protected);
    g_hBinCookie = new Cookie("prog_bin", "Progress Log: seconds per fail range in the window's stats and graph (5-60)", CookieAccess_Protected);

    RegConsoleCmd("sm_prog", Command_Prog, "Progress Log; sm_prog <from> to <to> logs an entry");
    RegConsoleCmd("sm_progsave", Command_ProgSave, "Progress Log: log the attempt you just played");
    RegConsoleCmd("sm_progmenu", Command_ProgMenu, "Progress Log: the menu");
    RegConsoleCmd("sm_progui", Command_ProgUI, "Progress Log window (CS:TV client) -> server");
    AddCommandListener(Listener_Say, "say");
    AddCommandListener(Listener_Say, "say_team");
    HookEvent("player_death", Event_PlayerDeath);

    char error[256];
    g_hDB = SQLite_UseDatabase("progresslog", error, sizeof(error));
    if (g_hDB == null)
        SetFailState("Progress Log: no database (%s)", error);
    SQL_FastQuery(g_hDB, "CREATE TABLE IF NOT EXISTS prog_entries (id INTEGER PRIMARY KEY AUTOINCREMENT, steamid TEXT NOT NULL, map TEXT NOT NULL, day TEXT NOT NULL, created INTEGER NOT NULL, from_text TEXT NOT NULL, from_time REAL, from_pct REAL, to_text TEXT NOT NULL, to_time REAL, to_pct REAL, source INTEGER NOT NULL DEFAULT 0, style INTEGER, track INTEGER)");
    SQL_FastQuery(g_hDB, "CREATE INDEX IF NOT EXISTS prog_entries_who ON prog_entries (steamid, map, day)");
    SQL_FastQuery(g_hDB, "CREATE TABLE IF NOT EXISTS prog_spots (steamid TEXT NOT NULL, map TEXT NOT NULL, name TEXT NOT NULL COLLATE NOCASE, pct REAL, time REAL, PRIMARY KEY (steamid, map, name))");
    // 2.1: time = where the spot's range starts, time_hi = where it ends (NULL: just the one time)
    DBResultSet cols = SQL_Query(g_hDB, "SELECT 1 FROM pragma_table_info('prog_spots') WHERE name = 'time_hi'");
    if (cols != null && !cols.FetchRow())
        SQL_FastQuery(g_hDB, "ALTER TABLE prog_spots ADD COLUMN time_hi REAL");
    delete cols;

    CreateTimer(0.05, Timer_Send, _, TIMER_REPEAT);
    CreateTimer(0.25, Timer_Live, _, TIMER_REPEAT);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;
        if (Shavit_GetTimerStatus(i) != Timer_Stopped)
            BeginAttempt(i, Shavit_IsPracticeMode(i) ? "?" : "Start", Shavit_IsPracticeMode(i) ? -1.0 : 0.0);
        ClientCommand(i, "prog_ui hello");
    }
}

public void OnClientPutInServer(int client)
{
    g_bAttempt[client] = false;
    g_iAttemptEntry[client] = 0;
    g_fFailAt[client] = 0.0;
    g_iInput[client] = INPUT_NONE;
    g_bUI[client] = g_bViewing[client] = false;
    delete g_hOut[client];
    if (!IsFakeClient(client))
        CreateTimer(2.0, Timer_Hello, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client)
{
    delete g_hOut[client];
    g_bUI[client] = g_bViewing[client] = false;
}

// clients with the CS:TV client answer (sm_progui hello); the others print "Unknown command" in their console
public Action Timer_Hello(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client))
        ClientCommand(client, "prog_ui hello");
    return Plugin_Stop;
}

// ==================== the attempt ====================

void BeginAttempt(int client, const char[] from, float fromTime)
{
    g_bAttempt[client] = true;
    strcopy(g_sFrom[client], MAX_TEXT, from);
    g_fFromTime[client] = fromTime;
    g_fAttemptStart[client] = GetGameTime();
    g_iAttemptEntry[client] = 0;
    g_fFailAt[client] = 0.0;
    g_bHavePos[client] = false;
}

public Action Shavit_OnStart(int client, int track)
{
    if (!IsFakeClient(client))
        BeginAttempt(client, "Start", 0.0);
    return Plugin_Continue;
}

public void Shavit_OnRestart(int client, int track)
{
    g_bAttempt[client] = false;
}

// practice: loading a checkpoint starts an attempt from your time there (restored next frame)
public Action Shavit_OnTeleport(int client, int index, int target)
{
    if (!IsFakeClient(client))
        RequestFrame(Frame_AfterTeleport, GetClientUserId(client));
    return Plugin_Continue;
}

public void Frame_AfterTeleport(any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client))
        return;
    float time = Shavit_GetClientTime(client);
    char from[MAX_TEXT];
    FormatClock(time, from, sizeof(from));
    BeginAttempt(client, from, time);
}

// a finished run (practice ones too) is "<from> to End"
public void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp)
{
    if (client < 1 || client > MaxClients || IsFakeClient(client) || !g_bAttempt[client] || !CookieOn(client, g_hAutoFinishCookie, true))
        return;
    if (SaveAttempt(client, "End", time, 2) > 0)
        PrintSaved(client, g_sFrom[client], g_fFromTime[client], "End", time);
    g_bAttempt[client] = false;
}

// fails: the map teleporting you (the position jumps further than you could move in a tick), or dying
public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
    if (!g_bAttempt[client] || !IsPlayerAlive(client) || IsFakeClient(client))
        return;
    float pos[3], speed[3];
    GetClientAbsOrigin(client, pos);
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", speed);
    float time = Shavit_GetClientTime(client);
    if (g_bHavePos[client] && Shavit_GetTimerStatus(client) == Timer_Running)
    {
        float reach = GetVectorLength(speed) * GetTickInterval() * 2.0 + 64.0;
        if (GetVectorDistance(pos, g_fLastPos[client]) > reach)
        {
            g_fFailTime[client] = g_fLastTime[client];
            g_fFailAt[client] = GetGameTime();
        }
    }
    g_fLastPos[client] = pos;
    g_fLastTime[client] = time;
    g_bHavePos[client] = true;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && g_bAttempt[client] && Shavit_GetTimerStatus(client) != Timer_Stopped)
    {
        g_fFailTime[client] = Shavit_GetClientTime(client);
        g_fFailAt[client] = GetGameTime();
    }
}

// where the attempt ended: the last fail if it was recent, else where you are
float AttemptEnd(int client)
{
    if (!CookieOn(client, g_hSaveAtCookie, false) && g_fFailAt[client] > g_fAttemptStart[client] && GetGameTime() - g_fFailAt[client] < FAIL_WINDOW)
        return g_fFailTime[client];
    return Shavit_GetClientTime(client);
}

public Action Command_ProgSave(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;
    if (!g_bAttempt[client])
    {
        if (Shavit_GetTimerStatus(client) == Timer_Stopped)
        {
            PrintToChat(client, "%s Start a run or load a checkpoint first.", PREFIX);
            return Plugin_Handled;
        }
        BeginAttempt(client, Shavit_IsPracticeMode(client) ? "?" : "Start", Shavit_IsPracticeMode(client) ? -1.0 : 0.0);
    }
    float toTime = AttemptEnd(client);
    char to[MAX_TEXT];
    FormatClock(toTime, to, sizeof(to));
    if (SaveAttempt(client, to, toTime, 1) > 0)
        PrintSaved(client, g_sFrom[client], g_fFromTime[client], to, toTime);
    return Plugin_Handled;
}

// [Prog] Saved 0:22 (8%) to 0:23 (8%).
void PrintSaved(int client, const char[] from, float fromTime, const char[] to, float toTime)
{
    float end = EndTime(client);
    char f[64], t[64];
    PointLabel(from, fromTime, end, f, sizeof(f));
    PointLabel(to, toTime, end, t, sizeof(t));
    PrintToChat(client, "%s Saved %s to %s.", PREFIX, f, t);
}

// saves (or for the same attempt, updates) the attempt's entry; returns its id
int SaveAttempt(int client, const char[] to, float toTime, int source)
{
    if (g_iAttemptEntry[client] > 0)
    {
        char eTo[MAX_TEXT * 2 + 1], sToTime[16], query[512];
        g_hDB.Escape(to, eTo, sizeof(eTo));
        NumOrNull(toTime, sToTime, sizeof(sToTime));
        Format(query, sizeof(query), "UPDATE prog_entries SET to_text = '%s', to_time = %s, source = %d WHERE id = %d", eTo, sToTime, source, g_iAttemptEntry[client]);
        if (!SQL_FastQuery(g_hDB, query))
            return LogDBError(client);
        QueueEntry(client, g_iAttemptEntry[client]);
        return g_iAttemptEntry[client];
    }
    int id = InsertEntry(client, g_sFrom[client], g_fFromTime[client], to, toTime, source);
    g_iAttemptEntry[client] = id;
    return id;
}

// ==================== entries ====================

int InsertEntry(int client, const char[] from, float fromTime, const char[] to, float toTime, int source)
{
    char auth[64], map[PLATFORM_MAX_PATH], day[16];
    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
    {
        PrintToChat(client, "%s Can't save yet (no Steam ID).", PREFIX);
        return 0;
    }
    CurrentMap(map, sizeof(map));
    int now = GetTime();
    DayOf(now, day, sizeof(day));
    char eFrom[MAX_TEXT * 2 + 1], eTo[MAX_TEXT * 2 + 1], eMap[PLATFORM_MAX_PATH * 2 + 1], sFromTime[16], sToTime[16], query[1024];
    g_hDB.Escape(from, eFrom, sizeof(eFrom));
    g_hDB.Escape(to, eTo, sizeof(eTo));
    g_hDB.Escape(map, eMap, sizeof(eMap));
    NumOrNull(fromTime, sFromTime, sizeof(sFromTime));
    NumOrNull(toTime, sToTime, sizeof(sToTime));
    Format(query, sizeof(query), "INSERT INTO prog_entries (steamid, map, day, created, from_text, from_time, to_text, to_time, source, style, track) VALUES ('%s', '%s', '%s', %d, '%s', %s, '%s', %s, %d, %d, %d)",
        auth, eMap, day, now, eFrom, sFromTime, eTo, sToTime, source, Shavit_GetBhopStyle(client), Shavit_GetClientTrack(client));
    if (!SQL_FastQuery(g_hDB, query))
        return LogDBError(client);
    int id = SQL_GetInsertId(g_hDB);
    QueueEntry(client, id);
    return id;
}

int LogDBError(int client)
{
    char error[256];
    SQL_GetError(g_hDB, error, sizeof(error));
    LogError("Progress Log: %s", error);
    PrintToChat(client, "%s Couldn't save (database error, see the server log).", PREFIX);
    return 0;
}

bool UpdatePoint(int client, int id, bool from, const char[] input)
{
    char point[MAX_TEXT], ePoint[MAX_TEXT * 2 + 1], sTime[16], query[512];
    float time;
    if (!ParsePoint(client, input, point, sizeof(point), time))
        return false;
    g_hDB.Escape(point, ePoint, sizeof(ePoint));
    NumOrNull(time, sTime, sizeof(sTime));
    Format(query, sizeof(query), "UPDATE prog_entries SET %s_text = '%s', %s_time = %s WHERE id = %d", from ? "from" : "to", ePoint, from ? "from" : "to", sTime, id);
    SQL_FastQuery(g_hDB, query);
    QueueEntry(client, id);
    return true;
}

void DeleteEntry(int client, int id)
{
    char query[128];
    Format(query, sizeof(query), "DELETE FROM prog_entries WHERE id = %d", id);
    SQL_FastQuery(g_hDB, query);
    for (int i = 1; i <= MaxClients; i++)
        if (g_iAttemptEntry[i] == id)
            g_iAttemptEntry[i] = 0;
    QueueLine(client, "prog_ui d %d", id);
}

// what someone typed for one end: Start, End, a run time (2:24, 224, 3:33.5, 1:02:03, 95s) or a spot's name
bool ParsePoint(int client, const char[] input, char[] text, int textLen, float &time)
{
    char s[64];
    strcopy(s, sizeof(s), input);
    StripQuotes(s);
    Sanitize(s);
    TrimString(s);
    time = -1.0;
    if (!s[0])
        return false;
    if (StrEqual(s, "start", false))
    {
        strcopy(text, textLen, "Start");
        time = 0.0;
        return true;
    }
    float t;
    if (ParseClock(s, t))
    {
        time = t;
        FormatClock(t, text, textLen);
        return true;
    }
    if (LooksLikeTime(s))
        return false;
    if (StrEqual(s, "end", false))
        strcopy(text, textLen, "End");
    else
        strcopy(text, textLen < MAX_TEXT ? textLen : MAX_TEXT, s);
    SpotTime(client, text, time);
    return true;
}

// "1:00", "3:33.5", "1:02:03"; digits alone read like a timer: "224" = 2:24, "10203" = 1:02:03, "45" = 0:45
// ("290" isn't a time); a trailing s means seconds: "95s", "224s" = 3:44
bool ParseClock(const char[] s, float &out)
{
    int len = strlen(s);
    bool secs = len > 0 && (s[len - 1] == 's' || s[len - 1] == 'S');
    if (secs)
        len--;
    if (!len)
        return false;
    int total = 0, part = 0, whole = 0, colons = 0;	// whole: the part's digits before a dot
    float frac = 0.0, scale = 0.1;
    bool dot = false;
    for (int i = 0; i < len; i++)
    {
        int c = s[i];
        if (c >= '0' && c <= '9')
        {
            if (dot) { frac += (c - '0') * scale; scale *= 0.1; }
            else if (++whole > 6) return false;
            else part = part * 10 + (c - '0');
        }
        else if (c == ':' && !dot && whole && colons < 2)
        {
            total = (total + part) * 60;
            part = 0;
            whole = 0;
            colons++;
        }
        else if (c == '.' && !dot)
            dot = true;
        else
            return false;
    }
    if (!whole)
        return false;
    if (!colons && !secs && whole > 2)
    {
        int ss = part % 100, mm = part / 100 % 100, hh = part / 10000;
        if (ss >= 60 || (hh && mm >= 60))
            return false;
        part = (hh * 60 + mm) * 60 + ss;
    }
    out = float(total + part) + frac;
    return true;
}

// typed as a time (digits, : and .) but not one, like "290": not a spot's name either
bool LooksLikeTime(const char[] s)
{
    if (s[0] < '0' || s[0] > '9')
        return false;
    for (int i = 1; s[i]; i++)
        if ((s[i] < '0' || s[i] > '9') && s[i] != ':' && s[i] != '.')
            return false;
    return true;
}

// "3:45" (hi = -1) or "3:40-3:55"
bool ParseRange(const char[] s, float &lo, float &hi)
{
    hi = -1.0;
    int dash = FindCharInString(s, '-');
    if (dash <= 0)
        return ParseClock(s, lo);
    char a[32];
    strcopy(a, dash + 1 < sizeof(a) ? dash + 1 : sizeof(a), s);
    TrimString(a);
    char b[32];
    strcopy(b, sizeof(b), s[dash + 1]);
    TrimString(b);
    return ParseClock(a, lo) && ParseClock(b, hi);
}

int BinSize(int client)
{
    if (!AreClientCookiesCached(client))
        return 10;
    char v[8];
    g_hBinCookie.Get(client, v, sizeof(v));
    int n = StringToInt(v);
    return n < 5 || n > 60 ? 10 : n;
}

void FormatClock(float t, char[] out, int len)
{
    int secs = RoundToFloor(t + 0.0001);
    if (secs < 0)
        secs = 0;
    if (secs >= 3600)
        Format(out, len, "%d:%02d:%02d", secs / 3600, (secs / 60) % 60, secs % 60);
    else
        Format(out, len, "%d:%02d", secs / 60, secs % 60);
}

// "0:22 (8%)", "Start", "End", "End slope"
void PointLabel(const char[] text, float time, float end, char[] out, int len)
{
    float t;
    if (end > 0.0 && time >= 0.0 && ParseClock(text, t))
        Format(out, len, "%s (%.0f%%)", text, time / end * 100.0 < 100.0 ? time / end * 100.0 : 100.0);
    else
        strcopy(out, len, text);
}

bool SplitEntry(const char[] input, char[] from, int fromLen, char[] to, int toLen)
{
    static const char seps[][] = { " to ", "->", " - " };
    for (int i = 0; i < sizeof(seps); i++)
    {
        int at = StrContains(input, seps[i], false);
        if (at <= 0)
            continue;
        strcopy(from, at + 1 < fromLen ? at + 1 : fromLen, input);
        strcopy(to, toLen, input[at + strlen(seps[i])]);
        return true;
    }
    return false;
}

bool AddPoints(int client, const char[] a, const char[] b)
{
    char fromText[MAX_TEXT], toText[MAX_TEXT];
    float fromTime, toTime;
    if (!ParsePoint(client, a, fromText, sizeof(fromText), fromTime) || !ParsePoint(client, b, toText, sizeof(toText), toTime))
        return false;
    if (InsertEntry(client, fromText, fromTime, toText, toTime, 0) > 0)
        PrintSaved(client, fromText, fromTime, toText, toTime);
    return true;
}

bool AddTyped(int client, const char[] input)
{
    char a[64], b[64];
    if (!SplitEntry(input, a, sizeof(a), b, sizeof(b)) || !AddPoints(client, a, b))
    {
        PrintToChat(client, "%s Like \x042:24 to 4:02\x01, \x04224 to 402\x01 or \x04Start to End slope\x01.", PREFIX);
        return false;
    }
    return true;
}

// ==================== spots: a name for a time ("End" = your estimated finish) ====================

bool SpotTime(int client, const char[] name, float &time)
{
    char where[512], eName[MAX_TEXT * 2 + 1], query[768];
    if (!WhoWhere(client, where, sizeof(where), true))
        return false;
    g_hDB.Escape(name, eName, sizeof(eName));
    Format(query, sizeof(query), "SELECT time, time_hi FROM prog_spots WHERE %s AND name = '%s' AND time IS NOT NULL", where, eName);
    DBResultSet rs = SQL_Query(g_hDB, query);
    bool found = rs != null && rs.FetchRow();
    if (found)
        time = SpotMiddle(rs.FetchFloat(0), rs.IsFieldNull(1) ? -1.0 : rs.FetchFloat(1));
    delete rs;
    return found;
}

float EndTime(int client)
{
    float t = -1.0;
    SpotTime(client, "End", t);
    return t;
}

// where entries that name a spot are: the middle of its range
float SpotMiddle(float lo, float hi)
{
    return hi > lo ? (lo + hi) * 0.5 : lo;
}

// a spot's range (hi < 0: just the one time); entries that use its name follow it. "End" is one time.
void SetSpot(int client, const char[] input, float time, float hi = -1.0)
{
    char name[MAX_TEXT], where[512], eName[MAX_TEXT * 2 + 1], sTime[16], sHi[16], sMid[16], auth[64], map[PLATFORM_MAX_PATH], eMap[PLATFORM_MAX_PATH * 2 + 1], query[1024];
    strcopy(name, sizeof(name), input);
    StripQuotes(name);
    Sanitize(name);
    TrimString(name);
    if (!name[0] || StrEqual(name, "start", false) || time < 0.0 || !WhoWhere(client, where, sizeof(where)))
        return;
    if (StrEqual(name, "end", false))
    {
        strcopy(name, sizeof(name), "End");
        hi = -1.0;
    }
    if (hi >= 0.0 && hi < time)
    {
        float t = hi;
        hi = time;
        time = t;
    }
    if (hi <= time)
        hi = -1.0;
    GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth));
    CurrentMap(map, sizeof(map));
    g_hDB.Escape(name, eName, sizeof(eName));
    g_hDB.Escape(map, eMap, sizeof(eMap));
    NumOrNull(time, sTime, sizeof(sTime));
    NumOrNull(hi, sHi, sizeof(sHi));
    NumOrNull(SpotMiddle(time, hi), sMid, sizeof(sMid));
    Format(query, sizeof(query), "INSERT OR REPLACE INTO prog_spots (steamid, map, name, pct, time, time_hi) VALUES ('%s', '%s', '%s', NULL, %s, %s)", auth, eMap, eName, sTime, sHi);
    SQL_FastQuery(g_hDB, query);
    if (!StrEqual(name, "End"))	// (finished runs keep their own time)
    {
        Format(query, sizeof(query), "UPDATE prog_entries SET from_time = %s WHERE %s AND from_text = '%s' COLLATE NOCASE", sMid, where, eName);
        SQL_FastQuery(g_hDB, query);
        Format(query, sizeof(query), "UPDATE prog_entries SET to_time = %s WHERE %s AND to_text = '%s' COLLATE NOCASE", sMid, where, eName);
        SQL_FastQuery(g_hDB, query);
    }
    QueueLine(client, "prog_ui s \"%s\" %.2f %.2f", name, time, hi);
    QueueEntriesNamed(client, name);
    char clock[16], clockHi[16];
    FormatClock(time, clock, sizeof(clock));
    if (hi >= 0.0)
    {
        FormatClock(hi, clockHi, sizeof(clockHi));
        PrintToChat(client, "%s Saved %s at %s-%s.", PREFIX, name, clock, clockHi);
    }
    else
        PrintToChat(client, "%s Saved %s at %s.", PREFIX, name, clock);
}

void DeleteSpot(int client, const char[] input)
{
    char name[MAX_TEXT], where[512], eName[MAX_TEXT * 2 + 1], query[768];
    strcopy(name, sizeof(name), input);
    Sanitize(name);
    if (!name[0] || !WhoWhere(client, where, sizeof(where)))
        return;
    g_hDB.Escape(name, eName, sizeof(eName));
    Format(query, sizeof(query), "DELETE FROM prog_spots WHERE %s AND name = '%s'", where, eName);
    SQL_FastQuery(g_hDB, query);
    QueueLine(client, "prog_ui sd \"%s\"", name);
}

// ==================== the CS:TV client's window ====================

void QueueLine(int client, const char[] fmt, any ...)
{
    if (!g_bUI[client])
        return;
    char line[256];
    VFormat(line, sizeof(line), fmt, 3);
    if (g_hOut[client] == null)
        g_hOut[client] = new ArrayList(ByteCountToCells(256));
    g_hOut[client].PushString(line);
}

public Action Timer_Send(Handle timer)
{
    char line[256];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_hOut[i] == null || !g_hOut[i].Length)
            continue;
        if (!IsClientInGame(i))
        {
            delete g_hOut[i];
            continue;
        }
        int n = g_hOut[i].Length < OUT_PER_TICK ? g_hOut[i].Length : OUT_PER_TICK;
        for (int k = 0; k < n; k++)
        {
            g_hOut[i].GetString(k, line, sizeof(line));
            ClientCommand(i, "%s", line);
        }
        for (int k = 0; k < n; k++)
            g_hOut[i].Erase(0);
    }
    return Plugin_Continue;
}

// the attempt being played, 4 times a second while the window is open
public Action Timer_Live(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!g_bViewing[i] || !IsClientInGame(i))
            continue;
        if (g_bAttempt[i] && Shavit_GetTimerStatus(i) != Timer_Stopped)
        {
            float fail = g_fFailAt[i] > g_fAttemptStart[i] && GetGameTime() - g_fFailAt[i] < FAIL_WINDOW ? g_fFailTime[i] : -1.0;
            ClientCommand(i, "prog_ui attempt 1 \"%s\" %.2f %.2f %.2f", g_sFrom[i], g_fFromTime[i], Shavit_GetClientTime(i), fail);
        }
        else
            ClientCommand(i, "prog_ui attempt 0 \"\" -1 -1 -1");
    }
    return Plugin_Continue;
}

#define ENTRY_COLUMNS "id, day, created, source, from_text, from_time, to_text, to_time"

void QueueEntryRow(int client, DBResultSet rs)
{
    char day[16], from[MAX_TEXT], to[MAX_TEXT];
    rs.FetchString(1, day, sizeof(day));
    rs.FetchString(4, from, sizeof(from));
    rs.FetchString(6, to, sizeof(to));
    QueueLine(client, "prog_ui e %d %s %d %d \"%s\" %.2f \"%s\" %.2f", rs.FetchInt(0), day, rs.FetchInt(2), rs.FetchInt(3),
        from, rs.IsFieldNull(5) ? -1.0 : rs.FetchFloat(5), to, rs.IsFieldNull(7) ? -1.0 : rs.FetchFloat(7));
}

void QueueEntry(int client, int id)
{
    if (!g_bUI[client] || id <= 0)
        return;
    char query[256];
    Format(query, sizeof(query), "SELECT " ... ENTRY_COLUMNS ... " FROM prog_entries WHERE id = %d", id);
    DBResultSet rs = SQL_Query(g_hDB, query);
    if (rs != null && rs.FetchRow())
        QueueEntryRow(client, rs);
    delete rs;
}

void QueueEntriesNamed(int client, const char[] name)
{
    char where[512], eName[MAX_TEXT * 2 + 1], query[1024];
    if (!g_bUI[client] || !WhoWhere(client, where, sizeof(where)))
        return;
    g_hDB.Escape(name, eName, sizeof(eName));
    Format(query, sizeof(query), "SELECT " ... ENTRY_COLUMNS ... " FROM prog_entries WHERE %s AND (from_text = '%s' COLLATE NOCASE OR to_text = '%s' COLLATE NOCASE)", where, eName, eName);
    DBResultSet rs = SQL_Query(g_hDB, query);
    while (rs != null && rs.FetchRow())
        QueueEntryRow(client, rs);
    delete rs;
}

void QueueCfg(int client)
{
    char today[16];
    DayOf(GetTime(), today, sizeof(today));
    QueueLine(client, "prog_ui cfg %d %d %d %s %d", CookieOn(client, g_hAutoFinishCookie, true), CookieOn(client, g_hSaveAtCookie, false), g_cvDayStart.IntValue, today, BinSize(client));
}

// everything on this map: the window starts over with it
void QueueSync(int client)
{
    char where[512], map[PLATFORM_MAX_PATH], today[16], query[1024];
    if (!g_bUI[client] || !WhoWhere(client, where, sizeof(where)))
        return;
    if (g_hOut[client] != null)
        g_hOut[client].Clear();
    CurrentMap(map, sizeof(map));
    DayOf(GetTime(), today, sizeof(today));
    QueueLine(client, "prog_ui reset \"%s\" %s %d %d %d %d", map, today, g_cvDayStart.IntValue, CookieOn(client, g_hAutoFinishCookie, true), CookieOn(client, g_hSaveAtCookie, false), BinSize(client));
    Format(query, sizeof(query), "SELECT " ... ENTRY_COLUMNS ... " FROM prog_entries WHERE %s ORDER BY id", where);
    DBResultSet rs = SQL_Query(g_hDB, query);
    while (rs != null && rs.FetchRow())
        QueueEntryRow(client, rs);
    delete rs;
    Format(query, sizeof(query), "SELECT name, time, time_hi FROM prog_spots WHERE %s AND time IS NOT NULL", where);
    rs = SQL_Query(g_hDB, query);
    while (rs != null && rs.FetchRow())
    {
        char name[MAX_TEXT];
        rs.FetchString(0, name, sizeof(name));
        QueueLine(client, "prog_ui s \"%s\" %.2f %.2f", name, rs.FetchFloat(1), rs.IsFieldNull(2) ? -1.0 : rs.FetchFloat(2));
    }
    delete rs;
    QueueLine(client, "prog_ui done");
}

bool OwnsEntry(int client, int id)
{
    char auth[64], query[256];
    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
        return false;
    Format(query, sizeof(query), "SELECT 1 FROM prog_entries WHERE id = %d AND steamid = '%s'", id, auth);
    DBResultSet rs = SQL_Query(g_hDB, query);
    bool ok = rs != null && rs.FetchRow();
    delete rs;
    return ok;
}

public Action Command_ProgUI(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || args < 1)
        return Plugin_Handled;
    char verb[16], a[64], b[64], c[64];
    GetCmdArg(1, verb, sizeof(verb));
    GetCmdArg(2, a, sizeof(a));
    GetCmdArg(3, b, sizeof(b));
    GetCmdArg(4, c, sizeof(c));
    if (StrEqual(verb, "hello"))
    {
        g_bUI[client] = StringToInt(a) >= 2;	// (1 = the window from before times only: it'd misread the lines)
        QueueSync(client);
    }
    else if (StrEqual(verb, "sync"))
        QueueSync(client);
    else if (StrEqual(verb, "view"))
    {
        g_bViewing[client] = StringToInt(a) != 0;
        if (g_bViewing[client])
            QueueCfg(client);
    }
    else if (StrEqual(verb, "add"))
    {
        if (!AddPoints(client, a, b))
            QueueLine(client, "prog_ui msg \"2:24 or 224, Start, End or a spot\"");
    }
    else if (StrEqual(verb, "edit"))
    {
        int id = StringToInt(a);
        if ((StrEqual(b, "from") || StrEqual(b, "to")) && OwnsEntry(client, id) && !UpdatePoint(client, id, StrEqual(b, "from"), c))
            QueueLine(client, "prog_ui msg \"2:24 or 224, Start, End or a spot\"");
    }
    else if (StrEqual(verb, "del"))
    {
        int id = StringToInt(a);
        if (OwnsEntry(client, id))
            DeleteEntry(client, id);
    }
    else if (StrEqual(verb, "spot"))	// spot "<name>" "<from>" ["<to>"]  (or "<from>-<to>" in one)
    {
        float lo, hi = -1.0;
        bool ok = ParseRange(b, lo, hi);
        if (ok && c[0] && !StrEqual(c, b))
            ok = ParseClock(c, hi);
        if (ok)
            SetSpot(client, a, lo, hi);
        else
            QueueLine(client, "prog_ui msg \"times like 3:40 and 3:55\"");
    }
    else if (StrEqual(verb, "spotdel"))
        DeleteSpot(client, a);
    else if (StrEqual(verb, "set"))
    {
        bool on = StringToInt(b) != 0;
        if (StrEqual(a, "autofinish"))
            g_hAutoFinishCookie.Set(client, on ? "1" : "0");
        else if (StrEqual(a, "saveat"))
            g_hSaveAtCookie.Set(client, on ? "1" : "0");
        else if (StrEqual(a, "bin"))
        {
            int n = StringToInt(b);
            char v[8];
            IntToString(n < 5 ? 5 : n > 60 ? 60 : n, v, sizeof(v));
            g_hBinCookie.Set(client, v);
        }
        QueueCfg(client);
    }
    return Plugin_Handled;
}

// ==================== !prog, and the menu for clients without the window ====================

public Action Command_Prog(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;
    if (args > 0)
    {
        char text[192];
        GetCmdArgString(text, sizeof(text));
        AddTyped(client, text);
        return Plugin_Handled;
    }
    if (g_bUI[client])
        ClientCommand(client, "prog_ui open");
    else
    {
        // (the hello at join may have come before the client was ready: ask again, the menu if no answer)
        ClientCommand(client, "prog_ui hello");
        CreateTimer(0.6, Timer_ProgOpen, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
    return Plugin_Handled;
}

public Action Timer_ProgOpen(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Stop;
    if (g_bUI[client])
        ClientCommand(client, "prog_ui open");
    else
        ShowMainMenu(client);
    return Plugin_Stop;
}

public Action Command_ProgMenu(int client, int args)
{
    if (client > 0 && IsClientInGame(client))
        ShowMainMenu(client);
    return Plugin_Handled;
}

void AskInput(int client, int what, int entry, const char[] prompt)
{
    g_iInput[client] = what;
    g_iInputEntry[client] = entry;
    g_fInputTime[client] = GetGameTime();
    PrintToChat(client, "%s %s \x01(or \x04cancel\x01)", PREFIX, prompt);
}

public Action Listener_Say(int client, const char[] command, int argc)
{
    if (client <= 0 || g_iInput[client] == INPUT_NONE)
        return Plugin_Continue;
    if (GetGameTime() - g_fInputTime[client] > 120.0)
    {
        g_iInput[client] = INPUT_NONE;
        return Plugin_Continue;
    }
    char text[192];
    GetCmdArgString(text, sizeof(text));
    StripQuotes(text);
    TrimString(text);
    if (!text[0] || text[0] == '!' || text[0] == '/')
        return Plugin_Continue;
    int what = g_iInput[client], entry = g_iInputEntry[client];
    g_iInput[client] = INPUT_NONE;
    if (StrEqual(text, "cancel", false))
        return Plugin_Stop;
    switch (what)
    {
        case INPUT_ADD:
            AddTyped(client, text);
        case INPUT_EDIT_FROM, INPUT_EDIT_TO:
        {
            if (!UpdatePoint(client, entry, what == INPUT_EDIT_FROM, text))
                PrintToChat(client, "%s Like \x042:24\x01, \x04224\x01, \x04Start\x01, \x04End\x01 or a spot.", PREFIX);
            ShowEntryMenu(client, entry);
        }
        case INPUT_SPOT:
        {
            // "<name> <time>", "<name> <from>-<to>", "<name> <from> - <to>" / "to"
            ReplaceString(text, sizeof(text), " - ", "-");
            ReplaceString(text, sizeof(text), " to ", "-", false);
            int sp = FindCharInString(text, ' ', true);
            float lo, hi;
            if (sp > 0 && ParseRange(text[sp + 1], lo, hi))
            {
                text[sp] = '\0';
                SetSpot(client, text, lo, hi);
            }
            else
                PrintToChat(client, "%s Like \x04End slope 3:40-3:55\x01.", PREFIX);
        }
    }
    return Plugin_Stop;
}

// WHERE for this player's entries / spots on this map
bool WhoWhere(int client, char[] out, int len, bool quiet = false)
{
    char auth[64], map[PLATFORM_MAX_PATH], eMap[PLATFORM_MAX_PATH * 2 + 1];
    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
    {
        if (!quiet)
            PrintToChat(client, "%s No Steam ID yet, try again in a moment.", PREFIX);
        return false;
    }
    CurrentMap(map, sizeof(map));
    g_hDB.Escape(map, eMap, sizeof(eMap));
    Format(out, len, "steamid = '%s' AND map = '%s'", auth, eMap);
    return true;
}

void ShowMainMenu(int client)
{
    char where[512], map[PLATFORM_MAX_PATH], today[16], query[1024];
    if (!WhoWhere(client, where, sizeof(where)))
        return;
    CurrentMap(map, sizeof(map));
    DayOf(GetTime(), today, sizeof(today));
    Format(query, sizeof(query), "SELECT COUNT(*), MAX(CASE WHEN from_time < 0.5 THEN to_time END) FROM prog_entries WHERE %s AND day = '%s'", where, today);
    int tries = 0;
    float best = -1.0;
    DBResultSet rs = SQL_Query(g_hDB, query);
    if (rs != null && rs.FetchRow())
    {
        tries = rs.FetchInt(0);
        best = rs.IsFieldNull(1) ? -1.0 : rs.FetchFloat(1);
    }
    delete rs;
    char title[256], sBest[16] = "-";
    if (best >= 0.0)
        FormatClock(best, sBest, sizeof(sBest));
    Format(title, sizeof(title), "Progress Log - %s\nToday: %d tries, furthest from start %s\n ", map, tries, sBest);
    Menu menu = new Menu(MainMenuHandler);
    menu.SetTitle(title);
    menu.AddItem("add", "Add  (or !prog 2:24 to 4:02)");
    menu.AddItem("today", "Today");
    menu.AddItem("days", "Days");
    menu.AddItem("spot", "Add a spot  (End = your finish time)");
    menu.AddItem("finish", CookieOn(client, g_hAutoFinishCookie, true) ? "Log finished runs: on" : "Log finished runs: off");
    menu.AddItem("saveat", CookieOn(client, g_hSaveAtCookie, false) ? "!progsave ends: where you are" : "!progsave ends: last fail");
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MainMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
        delete menu;
    else if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(item, info, sizeof(info));
        if (StrEqual(info, "add"))
            AskInput(client, INPUT_ADD, 0, "Type it, like \x042:24 to 4:02\x01 or \x04224 to 402\x01:");
        else if (StrEqual(info, "today"))
        {
            DayOf(GetTime(), g_sViewDay[client], sizeof(g_sViewDay[]));
            ShowDayEntries(client);
        }
        else if (StrEqual(info, "days"))
            ShowDays(client);
        else if (StrEqual(info, "spot"))
            AskInput(client, INPUT_SPOT, 0, "Name and times, like \x04End slope 3:40-3:55\x01 or \x04End 4:10\x01:");
        else
        {
            if (StrEqual(info, "finish"))
                g_hAutoFinishCookie.Set(client, CookieOn(client, g_hAutoFinishCookie, true) ? "0" : "1");
            else
                g_hSaveAtCookie.Set(client, CookieOn(client, g_hSaveAtCookie, false) ? "0" : "1");
            ShowMainMenu(client);
        }
    }
    return 0;
}

void ShowDayEntries(int client)
{
    char where[512], query[1024];
    if (!WhoWhere(client, where, sizeof(where)))
        return;
    float end = EndTime(client);
    Format(query, sizeof(query), "SELECT id, from_text, from_time, to_text, to_time, created FROM prog_entries WHERE %s AND day = '%s' ORDER BY id DESC", where, g_sViewDay[client]);
    DBResultSet rs = SQL_Query(g_hDB, query);
    Menu menu = new Menu(DayEntriesHandler);
    char title[64];
    Format(title, sizeof(title), "%s\n ", g_sViewDay[client]);
    menu.SetTitle(title);
    while (rs != null && rs.FetchRow())
    {
        char id[12], from[MAX_TEXT], to[MAX_TEXT], f[48], t[48], clock[8], line[160];
        IntToString(rs.FetchInt(0), id, sizeof(id));
        rs.FetchString(1, from, sizeof(from));
        rs.FetchString(3, to, sizeof(to));
        PointLabel(from, rs.IsFieldNull(2) ? -1.0 : rs.FetchFloat(2), end, f, sizeof(f));
        PointLabel(to, rs.IsFieldNull(4) ? -1.0 : rs.FetchFloat(4), end, t, sizeof(t));
        FormatTime(clock, sizeof(clock), "%H:%M", rs.FetchInt(5));
        Format(line, sizeof(line), "%s to %s   [%s]", f, t, clock);
        menu.AddItem(id, line);
    }
    if (menu.ItemCount == 0)
        menu.AddItem("", "-", ITEMDRAW_DISABLED);
    delete rs;
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int DayEntriesHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
        delete menu;
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
        ShowMainMenu(client);
    else if (action == MenuAction_Select)
    {
        char info[12];
        menu.GetItem(item, info, sizeof(info));
        ShowEntryMenu(client, StringToInt(info));
    }
    return 0;
}

void ShowEntryMenu(int client, int id)
{
    char query[256];
    Format(query, sizeof(query), "SELECT from_text, to_text, day FROM prog_entries WHERE id = %d", id);
    DBResultSet rs = SQL_Query(g_hDB, query);
    if (rs == null || !rs.FetchRow())
    {
        delete rs;
        ShowDayEntries(client);
        return;
    }
    char from[MAX_TEXT], to[MAX_TEXT], title[128], sid[12];
    rs.FetchString(0, from, sizeof(from));
    rs.FetchString(1, to, sizeof(to));
    rs.FetchString(2, g_sViewDay[client], sizeof(g_sViewDay[]));
    delete rs;
    Format(title, sizeof(title), "%s to %s\n ", from, to);
    IntToString(id, sid, sizeof(sid));
    Menu menu = new Menu(EntryMenuHandler);
    menu.SetTitle(title);
    menu.AddItem(sid, "From");
    menu.AddItem(sid, "To");
    menu.AddItem(sid, "Delete");
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int EntryMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
        delete menu;
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
        ShowDayEntries(client);
    else if (action == MenuAction_Select)
    {
        char info[12];
        menu.GetItem(item, info, sizeof(info));
        int id = StringToInt(info);
        if (!OwnsEntry(client, id))
            return 0;
        if (item == 0)
            AskInput(client, INPUT_EDIT_FROM, id, "New \"from\":");
        else if (item == 1)
            AskInput(client, INPUT_EDIT_TO, id, "New \"to\":");
        else
        {
            DeleteEntry(client, id);
            ShowDayEntries(client);
        }
    }
    return 0;
}

void ShowDays(int client)
{
    char where[512], query[1024];
    if (!WhoWhere(client, where, sizeof(where)))
        return;
    Format(query, sizeof(query), "SELECT day, COUNT(*), MAX(CASE WHEN from_time < 0.5 THEN to_time END) FROM prog_entries WHERE %s GROUP BY day ORDER BY day DESC LIMIT 100", where);
    DBResultSet rs = SQL_Query(g_hDB, query);
    Menu menu = new Menu(DaysHandler);
    menu.SetTitle("Days\n ");
    while (rs != null && rs.FetchRow())
    {
        char day[16], line[96], best[16] = "-";
        rs.FetchString(0, day, sizeof(day));
        if (!rs.IsFieldNull(2))
            FormatClock(rs.FetchFloat(2), best, sizeof(best));
        Format(line, sizeof(line), "%s - %d tries, furthest %s", day, rs.FetchInt(1), best);
        menu.AddItem(day, line);
    }
    if (menu.ItemCount == 0)
        menu.AddItem("", "-", ITEMDRAW_DISABLED);
    delete rs;
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int DaysHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
        delete menu;
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
        ShowMainMenu(client);
    else if (action == MenuAction_Select)
    {
        menu.GetItem(item, g_sViewDay[client], sizeof(g_sViewDay[]));
        ShowDayEntries(client);
    }
    return 0;
}

// ==================== helpers ====================

bool CookieOn(int client, Cookie cookie, bool def)
{
    if (!AreClientCookiesCached(client))
        return def;
    char v[4];
    cookie.Get(client, v, sizeof(v));
    return v[0] ? v[0] != '0' : def;
}

void CurrentMap(char[] out, int len)
{
    char map[PLATFORM_MAX_PATH];
    GetCurrentMap(map, sizeof(map));
    GetMapDisplayName(map, out, len);
    for (int i = 0; out[i]; i++)
        out[i] = CharToLower(out[i]);
}

// the log's day for a time: before sm_prog_daystart counts as the day before
void DayOf(int timestamp, char[] out, int len)
{
    FormatTime(out, len, "%Y-%m-%d", timestamp - g_cvDayStart.IntValue * 3600);
}

void NumOrNull(float v, char[] out, int len)
{
    if (v < 0.0)
        strcopy(out, len, "NULL");
    else
        Format(out, len, "%.3f", v);
}

// what may go inside quotes in a console command line
void Sanitize(char[] s)
{
    int j = 0;
    for (int i = 0; s[i]; i++)
    {
        if (s[i] == '"' || s[i] == ';' || s[i] == '\\' || (s[i] > 0 && s[i] < ' '))
            continue;
        s[j++] = s[i];
    }
    s[j] = '\0';
}
