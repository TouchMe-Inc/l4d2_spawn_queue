#pragma semicolon               1
#pragma newdecls                required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>


public Plugin myinfo =
{
    name        = "VersusSpawnQueue",
    author      = "TouchMe",
    description = "The plugin sets the queue of infected in the order of their death",
    version     = "build0004",
    url         = "https://github.com/TouchMe-Inc/l4d2_spawn_queue"
}


#define TRANSLATIONS            "spawn_queue.phrases"

/*
 * Scheme.
 */
#define SCHEME_ORIGINAL         0
#define SCHEME_DYNAMIC_QUEUE    1
#define SCHEME_STRICT_THREE_CAP 2

/*
 * Team.
 */
#define TEAM_SURVIVOR           2
#define TEAM_INFECTED           3

/*
 * Infected Class.
 */
#define SI_CLASS_NONE           0
#define SI_CLASS_SMOKER         1
#define SI_CLASS_BOOMER         2
#define SI_CLASS_HUNTER         3
#define SI_CLASS_SPITTER        4
#define SI_CLASS_JOCKEY         5
#define SI_CLASS_CHARGER        6
#define SI_CLASS_TANK           8

/*
 * Sugar for left4dhooks.
 */
#define SetClientClass          L4D_SetClass
#define OnSpawnSpecial          L4D_OnSpawnSpecial
#define OnSpawnSpecial_Post     L4D_OnSpawnSpecial_Post
#define IsTankInPlay            L4D2_IsTankInPlay
#define OnEnterGhostStatePre    L4D_OnEnterGhostStatePre
#define OnEnterGhostState       L4D_OnEnterGhostState
#define GetResourceEntity       L4D_GetResourceEntity
#define OnFirstSurvivorLeftSafeArea_Post L4D_OnFirstSurvivorLeftSafeArea_Post


Handle g_hFirstQueue    = INVALID_HANDLE;
Handle g_hCurrentQueue  = INVALID_HANDLE;

bool g_bRoundIsLive = false;

int g_iSupportDeathAt = 0;

bool g_bInfectedWithClass[MAXPLAYERS + 1] = {false, ...};

/* survivor_limit */
ConVar g_cvInfectedLimit = null;
int g_iInfectedLimit = 0;

/* z_ghost_delay_min */
ConVar g_cvGhostDelay = null;
int g_iGhostDelay = 0;

/* sm_spawn_queue_mode */
ConVar g_cvMode = null;
int g_iMode = 0;

/* sm_spawn_queue_first_hit_required */
ConVar g_cvFirstHitReqired = null;
int g_iFirstHitReqired = 0;

/* sm_spawn_queue_support_switch */
ConVar g_cvSupportSwitch = null;
bool g_bSupportSwitch = false;

/* z_smoker_limit */
ConVar g_cvSmokerLimit = null;
int g_iSmokerLimit = 0;

/* z_boomer_limit */
ConVar g_cvBoomerLimit = null;
int g_iBoomerLimit = 0;

/* z_jockey_limit */
ConVar g_cvJockeyLimit = null;
int g_iJockeyLimit = 0;

/* z_spitter_limit */
ConVar g_cvSpitterLimit = null;
int g_iSpitterLimit = 0;

/* z_hunter_limit */
ConVar g_cvHunterLimit = null;
int g_iHunterLimit = 0;

/* z_charger_limit */
ConVar g_cvChargerLimit = null;
int g_iChargerLimit = 0;


/**
 * Plugin load handler with native and library registration.
 *
 * Verifies engine compatibility (Left 4 Dead 2 only).
 * Registers public natives for queue access and manipulation,
 * and exposes library "spawn_queue" for external plugins.
 *
 * @param myself         Handle to this plugin.
 * @param bLate          True if plugin is loaded late.
 * @param sErr           Buffer for error message (if any).
 * @param iErrLen        Length of the error message buffer.
 * @return               APLRes_Success if plugin loads successfully,
 *                       otherwise APLRes_SilentFailure.
 */
public APLRes AskPluginLoad2(Handle myself, bool bLate, char[] sErr, int iErrLen)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(sErr, iErrLen, "Plugin only supports Left 4 Dead 2");
        return APLRes_SilentFailure;
    }

    CreateNative("GetClassFromQueue", Native_GetClassFromQueue);
    CreateNative("MoveClassToEndQueue", Native_MoveClassToEndQueue);

    RegPluginLibrary("spawn_queue");

    return APLRes_Success;
}

/**
 * Native: Retrieves an infected class from the spawn queue at a given index.
 *
 * @param hPlugin        Plugin handle requesting the native.
 * @param iParams        Number of parameters (expected: 1).
 * @return               Class identifier at the specified index.
 *
 * @error                Throws SP_ERROR_NATIVE if index is out of bounds.
 *                       Valid range is [0, GetArraySize(g_hCurrentQueue) - 1].
 */
int Native_GetClassFromQueue(Handle hPlugin, int iParams)
{
    int iIndex = GetNativeCell(1);
    int iQueueSize = GetArraySize(g_hCurrentQueue);

    if (0 < iIndex || iIndex >= iQueueSize) {
        ThrowNativeError(SP_ERROR_NATIVE, "The parameter must have a value from 0 to %d", iQueueSize);
    }

    return GetArrayCell(g_hCurrentQueue, iIndex);
}

/**
 * Native: Moves a specified infected class to the end of the spawn queue.
 *
 * @param hPlugin        Plugin handle requesting the native.
 * @param iParams        Number of parameters (expected: 1).
 * @return               True (1) if class was successfully moved; false (0) otherwise.
 *
 * @error                Throws SP_ERROR_NATIVE if class identifier is invalid.
 *                       Valid range: SI_CLASS_SMOKER to SI_CLASS_CHARGER.
 */
int Native_MoveClassToEndQueue(Handle hPlugin, int iParams)
{
    int iInfectedClass = GetNativeCell(1);

    if (!IsValidInfectedClass(iInfectedClass)) {
        ThrowNativeError(SP_ERROR_NATIVE, "The parameter must have a value from %d to %d", SI_CLASS_SMOKER, SI_CLASS_CHARGER);
    }

    return MoveClassToEndQueue(iInfectedClass);
}

/**
 * Called when the plugin is fully initialized and all known external references are resolved.
 */
public void OnPluginStart()
{
    /*
     * Load plugin language translations.
     * Ensures multi-language support for messages and log output.
     */
    LoadTranslations(TRANSLATIONS);

    /*
     * Register essential gameplay event hooks.
     * These events govern round state, player activity, and spawn queue updates.
     */
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);

    /*
     * Initialize and bind console variables.
     * Controls spawn scheme and per-class spawn limits for infected bots.
     */
    g_cvInfectedLimit = FindConVar("survivor_limit");
    g_cvGhostDelay    = FindConVar("z_ghost_delay_min");

    g_cvSmokerLimit   = FindConVar("z_versus_smoker_limit");
    g_cvBoomerLimit   = FindConVar("z_versus_boomer_limit");
    g_cvJockeyLimit   = FindConVar("z_versus_jockey_limit");
    g_cvSpitterLimit  = FindConVar("z_versus_spitter_limit");
    g_cvHunterLimit   = FindConVar("z_versus_hunter_limit");
    g_cvChargerLimit  = FindConVar("z_versus_charger_limit");

    g_cvMode = CreateConVar(
        .name = "sm_spawn_queue_mode",
        .defaultValue = "0",
        .description = "The queue is made up of the order of deaths: 0 - Original; 1 - Dynamic; 2 - Strict 3cap"
    );
    g_cvFirstHitReqired = CreateConVar(
        .name = "sm_spawn_queue_first_hit_required",
        .defaultValue = "0",
        .description = "Bitmask of special infected classes required in the first attack wave:\n\
                        1 - SMOKER, 2 - BOOMER, 4 - HUNTER, 8 - SPITTER, 16 - JOCKEY, 32 - CHARGER\n \
                        Examples: 1 + 32 = 33 forces SMOKER and CHARGER"
    );
    g_cvSupportSwitch = CreateConVar(
        .name = "sm_spawn_queue_support_switch",
        .defaultValue = "1",
        .description = "1 - Enable; 0 - Disable"
    );

    /*
     * Monitor changes to ConVars to dynamically update internal state.
     */
    HookConVarChange(g_cvInfectedLimit, OnInfectedLimitChanged);
    HookConVarChange(g_cvGhostDelay, OnGhostDelayChanged);

    HookConVarChange(g_cvSmokerLimit, OnSmokerLimitChanged);
    HookConVarChange(g_cvBoomerLimit, OnBoomerLimitChanged);
    HookConVarChange(g_cvJockeyLimit, OnJockeyLimitChanged);
    HookConVarChange(g_cvSpitterLimit, OnSpitterLimitChanged);
    HookConVarChange(g_cvHunterLimit, OnHunterLimitChanged);
    HookConVarChange(g_cvChargerLimit, OnChargerLimitChanged);

    HookConVarChange(g_cvMode, OnModeChanged);
    HookConVarChange(g_cvFirstHitReqired, OnFirstHitRequiredChanged);
    HookConVarChange(g_cvSupportSwitch, OnSupportSwitchChanged);

    /*
     * Cache ConVar values at startup.
     * These values define spawn limits and queue scheme during live rounds.
     */
    g_iInfectedLimit = GetConVarInt(g_cvInfectedLimit);
    g_iGhostDelay    = GetConVarInt(g_cvGhostDelay);

    g_iSmokerLimit   = GetConVarInt(g_cvSmokerLimit);
    g_iBoomerLimit   = GetConVarInt(g_cvBoomerLimit);
    g_iJockeyLimit   = GetConVarInt(g_cvJockeyLimit);
    g_iSpitterLimit  = GetConVarInt(g_cvSpitterLimit);
    g_iHunterLimit   = GetConVarInt(g_cvHunterLimit);
    g_iChargerLimit  = GetConVarInt(g_cvChargerLimit);

    g_iMode          = GetConVarInt(g_cvMode);
    g_iFirstHitReqired = GetConVarInt(g_cvFirstHitReqired);
    g_bSupportSwitch = GetConVarBool(g_cvSupportSwitch);

    /*
     * Initialize spawn queue containers.
     * g_hFirstQueue — persistent base queue.
     * g_hCurrentQueue — live spawn queue that changes dynamically during gameplay.
     */
    g_hFirstQueue = CreateArray();
    g_hCurrentQueue = CreateArray();
}

/**
 * Filling out the first queue for teams.
 */
public void OnMapInit(const char[] szMap)
{
    GenerateFirstQueue();
    SyncWithFirstQueue();
}

/**
 * Callback triggered when the infected spawn limit configuration changes.
 */
public void OnInfectedLimitChanged(ConVar cv, const char[] szOldValue, const char[] szNewValue) {
    g_iInfectedLimit = GetConVarInt(cv);
}

/**
 * .
 */
public void OnGhostDelayChanged(ConVar cv, const char[] szOldValue, const char[] szNewValue) {
    g_iGhostDelay = GetConVarInt(cv);
}

/**
 * Callback triggered when the spawning mode configuration changes.
 */
public void OnModeChanged(ConVar cv, const char[] szOldValue, const char[] szNewValue) {
    g_iMode = GetConVarInt(cv);
}

/**
 * Callback triggered when the first-hit requirement configuration changes.
 */
public void OnFirstHitRequiredChanged(ConVar cv, const char[] szOldValue, const char[] szNewValue) {
    g_iFirstHitReqired = GetConVarInt(cv);
}

/**
 * .
 */
public void OnSupportSwitchChanged(ConVar cv, const char[] szOldValue, const char[] szNewValue) {
    g_bSupportSwitch = GetConVarBool(cv);
}

/**
 * Updates the internal Smoker limit used for spawn logic.
 */
public void OnSmokerLimitChanged(ConVar cv, const char[] szOldValue, const char[] szNewValue) {
    g_iSmokerLimit = GetConVarInt(cv);
}

/**
 * Updates the internal Boomer limit used for spawn logic.
 */
public void OnBoomerLimitChanged(ConVar cv, const char[] szOldValue, const char[] szNewValue) {
    g_iBoomerLimit = GetConVarInt(cv);
}

/**
 * Updates the internal Jockey limit used for spawn logic.
 */
public void OnJockeyLimitChanged(ConVar cv, const char[] szOldValue, const char[] szNewValue) {
    g_iJockeyLimit = GetConVarInt(cv);
}

/**
 * Updates the internal Spitter limit used for spawn logic.
 */
public void OnSpitterLimitChanged(ConVar cv, const char[] szOldValue, const char[] szNewValue) {
    g_iSpitterLimit = GetConVarInt(cv);
}

/**
 * Updates the internal Hunter limit used for spawn logic.
 */
public void OnHunterLimitChanged(ConVar cv, const char[] szOldValue, const char[] szNewValue) {
    g_iHunterLimit = GetConVarInt(cv);
}

/**
 * Updates the internal Charger limit used for spawn logic.
 */
public void OnChargerLimitChanged(ConVar cv, const char[] szOldValue, const char[] szNewValue) {
    g_iChargerLimit = GetConVarInt(cv);
}

/**
 * Setting the round status.
 */
void Event_RoundStart(Event event, char[] szEventName, bool bDontBroadcast)
{
    g_bRoundIsLive = false;
    g_iSupportDeathAt = 0;

    if (InSecondHalfOfRound()) {
        ValidateFirstQueue();
    }
}

/**
 * Setting the round status.
 */
public void OnFirstSurvivorLeftSafeArea_Post(int iClient) {
    g_bRoundIsLive = true;
}

/**
 * Event hook: Called when the round ends.
 *
 * Handles spawn queue synchronization based on round state:
 * - If round was live, simply marks it as inactive.
 * - If round was not live (e.g., between map loads or second half starts),
 *   regenerates or syncs the spawn queue accordingly.
 *
 * Behavior:
 * - In second half of a round: regenerates base queue and copies to active queue.
 * - In first half: just resynchronizes active queue from the existing base.
 *
 * @param event             Event data (unused)
 * @param szEventName       Event name string
 * @param bDontBroadcast    True if event shouldn't be broadcast to clients
 */
void Event_RoundEnd(Event event, char[] szEventName, bool bDontBroadcast)
{
    if (g_bRoundIsLive == true) {
        g_bRoundIsLive = false;

        if (L4D2_IsScavengeMode() && InSecondHalfOfRound()) {
            GenerateFirstQueue();
        }
    }
    else
    {
        for (int iClient = 1; iClient <= MaxClients; iClient++)
        {
            g_bInfectedWithClass[iClient] = false;
        }

        SyncWithFirstQueue();
    }
}

/**
 * Event hook: Called when an infected player dies.
 *
 * If the round is active (`g_bRoundIsLive`), this handler:
 * - Retrieves the dying client via event's "userid"
 * - Validates the client and ensures they're infected
 * - Fetches their infected class and validates it
 * - Moves the class to the end of the spawn queue to delay immediate respawn of same type
 *
 * @param event             Event data for "player_death"
 * @param szEventName       Name of the triggered event (typically "player_death")
 * @param bDontBroadcast    If true, suppresses broadcast to clients (unused here)
 */
void Event_PlayerDeath(Event event, const char[] szEventName, bool bDontBroadcast)
{
    if (!g_bRoundIsLive) {
        return;
    }

    int iClient = GetClientOfUserId(GetEventInt(event, "userid"));

    if (!IsValidClientIndex(iClient) || !IsClientInfected(iClient)) {
        return;
    }

    int iInfectedClass = GetClientInfectedClass(iClient);

    if (!IsValidInfectedClass(iInfectedClass)) {
        return;
    }

    MoveClassToEndQueue(iInfectedClass);

    if (IsSupportClass(iInfectedClass)) {
        g_iSupportDeathAt = GetTime();
    }

    g_bInfectedWithClass[iClient] = false;
}

public Action OnEnterGhostStatePre(int iClient)
{
    static int s_iOffs_m_bPZAbortedControl = -1;
    if (s_iOffs_m_bPZAbortedControl == -1) {
        s_iOffs_m_bPZAbortedControl = FindSendPropInfo("CTerrorPlayer", "m_bSurvivorGlowEnabled") + 1;
    }

    g_bInfectedWithClass[iClient] = GetEntData(iClient, s_iOffs_m_bPZAbortedControl, 1) != 0;

    return Plugin_Continue;
}

/**
 * Called when an infected client enters ghost state.
 *
 * @param iClient       Client index that entered ghost state
 */
public void OnEnterGhostState(int iClient)
{
    if (g_bInfectedWithClass[iClient]) {
        return;
    }

    SetClientClass(iClient, GetNextClassFromQueue());

    g_bInfectedWithClass[iClient] = true;
}

/**
 * Hook: Called when the game engine requests spawning of a special infected bot.
 *
 * Selects the next infected class from the queue and assigns it to be spawned.
 * If the round is not live, cancels the spawn request.
 *
 * @param iInfectedClass   Reference to the zombie class to be assigned
 * @param vPos             Requested spawn position (unused here)
 * @param vAng             Requested spawn angle (unused here)
 * @return                 Plugin_Handled if suppressed, Plugin_Changed if reassigned
 */
public Action OnSpawnSpecial(int &iInfectedClass, const float vPos[3], const float vAng[3])
{
    if (!g_bRoundIsLive) {
        return Plugin_Handled;
    }

    iInfectedClass = GetNextClassFromQueue();

    return Plugin_Changed;
}

/**
 * Move to end special infected class for bots.
 */
public void OnSpawnSpecial_Post(int iClient, int iInfectedClass, const float vPos[3], const float vAng[3])
{
    if (!g_bRoundIsLive) {
        return;
    }

    g_bInfectedWithClass[iClient] = true;

    MoveClassToEndQueue(iInfectedClass);
}

/**
 * Switching si class from Boomer to Spitter during the life of the tank.
 * Called when a clients movement buttons are being processed.
 */
public Action OnPlayerRunCmd(int iClient, int &iButtons, int &iImpulse, float vVel[3], float vAngles[3], int &iWeapon)
{
    if (!g_bRoundIsLive) {
        return Plugin_Continue;
    }

    if (!g_bSupportSwitch) {
        return Plugin_Continue;
    }

    if (
        !IsClientInfected(iClient) ||
        !IsClientGhost(iClient) ||
        !IsTankInPlay() ||
        GetInfectedCount(Filter_SupportOnly_WithDead) > 1
    ) {
        return Plugin_Continue;
    }

    if (g_iSupportDeathAt + g_iGhostDelay >= GetTime()) {
        return Plugin_Continue;
    }

    static bool g_bClientAttack2[MAXPLAYERS + 1] = {false, ...};

    /*
     * Player was holding m2, and now isn't.
     */
    if (iButtons & IN_ATTACK2 != IN_ATTACK2 && g_bClientAttack2[iClient]) {
        g_bClientAttack2[iClient] = false;
    }

    /*
     * Player was not holding m2, and now is.
     */
    if (iButtons & IN_ATTACK2 == IN_ATTACK2 && !g_bClientAttack2[iClient])
    {
        g_bClientAttack2[iClient] = true;

        switch (GetClientInfectedClass(iClient))
        {
            case SI_CLASS_BOOMER:
            {
                SetClientClass(iClient, SI_CLASS_SPITTER);
                PrintHintText(iClient, "%T", "BECOME_A_BOOMER", iClient);
            }

            case SI_CLASS_SPITTER:
            {
                SetClientClass(iClient, SI_CLASS_BOOMER);
                PrintHintText(iClient, "%T", "BECOME_A_SPITTER", iClient);
            }
        }

        MoveClassToEndQueue(SI_CLASS_BOOMER);
        MoveClassToEndQueue(SI_CLASS_SPITTER);
    }

    return Plugin_Continue;
}

/**
 * Generates the base spawn queue for infected classes.
 *
 * The queue is filled using current class limit ConVars.
 * Each class is added to the queue as many times as allowed by its configured limit.
 * The resulting queue is then randomized using Fisher-Yates shuffle.
 */
void GenerateFirstQueue()
{
    ClearArray(g_hFirstQueue);

    for (int iInfectedClass = SI_CLASS_SMOKER; iInfectedClass <= SI_CLASS_CHARGER; iInfectedClass++)
    {
        int iLimit = GetInfectedClassLimit(iInfectedClass);

        if (iLimit <= 0) {
            continue;
        }

        for (int i = 0; i < iLimit; i++) {
            PushArrayCell(g_hFirstQueue, iInfectedClass);
        }
    }

    if (g_iFirstHitReqired == 0)
    {
        ShuffleArray(g_hFirstQueue);
    }
    else
    {
        int iOffset = 0;

        for (int iInfectedClass = SI_CLASS_SMOKER; iInfectedClass <= SI_CLASS_CHARGER; iInfectedClass++)
        {
            int iBit = (1 << (iInfectedClass - 1));

            if ((g_iFirstHitReqired & iBit) != 0)
            {
                int iIndex = FindValueInArray(g_hFirstQueue, iInfectedClass);
                if (iIndex != -1)
                {
                    RemoveFromArray(g_hFirstQueue, iIndex);
                    InsertArrayCell(g_hFirstQueue, 0, iInfectedClass);
                    iOffset ++;
                }
            }
        }

        ShuffleArray(g_hFirstQueue, .iStart = iOffset);
        ShuffleArray(g_hFirstQueue, .iStart = 0, .iEnd = g_iInfectedLimit - 1);
    }
}

/**
 * Copies the base queue to the active queue.
 *
 * This function resets g_hCurrentQueue and fills it with the contents
 * of g_hFirstQueue, preserving spawn order at round start.
 */
void SyncWithFirstQueue()
{
    ClearArray(g_hCurrentQueue);

    int iFirstOrderSize = GetArraySize(g_hFirstQueue);

    for (int iIndex = 0; iIndex < iFirstOrderSize; iIndex++)
    {
        PushArrayCell(g_hCurrentQueue, GetArrayCell(g_hFirstQueue, iIndex));
    }
}

void ValidateFirstQueue()
{
    bool[] bChecked = new bool[MaxClients + 1];
    int[] iGhostPlayers = new int[MaxClients + 1];
    int iGhostCount = 0;

    for (int iClient = 1; iClient <= MaxClients; iClient++)
    {
        if (!IsClientInGame(iClient) || !IsClientInfected(iClient)) {
            continue;
        }

        if (!IsFakeClient(iClient) && IsClientGhost(iClient)) {
            iGhostPlayers[iGhostCount++] = iClient;
        }
    }

    Handle hFirstWaveClasses = CreateArray();

    for (int i = 0; i < iGhostCount && i < GetArraySize(g_hCurrentQueue); i++)
    {
        PushArrayCell(hFirstWaveClasses, GetArrayCell(g_hCurrentQueue, i));
    }

    for (int i = 0; i < iGhostCount; i++)
    {
        int iClient = iGhostPlayers[i];
        int iActualClass = GetClientInfectedClass(iClient);

        int iIndex = FindValueInArray(hFirstWaveClasses, iActualClass);

        if (iIndex != -1)
        {
            RemoveFromArray(hFirstWaveClasses, iIndex);
            bChecked[iClient] = true;
        }
    }

    for (int i = 0; i < iGhostCount; i++)
    {
        int iClient = iGhostPlayers[i];

        if (!bChecked[iClient] && GetArraySize(hFirstWaveClasses) > 0)
        {
            int iCorrectClass = GetArrayCell(hFirstWaveClasses, 0);
            RemoveFromArray(hFirstWaveClasses, 0);

            SetClientClass(iClient, iCorrectClass);
        }
    }

    CloseHandle(hFirstWaveClasses);
}

/**
 * Retrieves the next infected class from the spawn queue based on current round state and spawn scheme.
 *
 * Applies the following constraints:
 * - In CLASSIC mode: limits dominator count to 3 alive at once.
 * - If Tank is in play: Spitter is deprioritized and pushed to queue end.
 * - Respects per-class spawn limits.
 *
 * @return         Infected class identifier to spawn next, or -1 if no valid class is found.
 */
int GetNextClassFromQueue()
{
    int iIndex = 0;
    int iQueueSize = GetArraySize(g_hCurrentQueue);

    while (iIndex < iQueueSize)
    {
        int iNextClass = GetArrayCell(g_hCurrentQueue, iIndex);

        switch (g_iMode)
        {
            case SCHEME_ORIGINAL: {
                if (
                    IsDominatorClass(iNextClass) &&
                    GetInfectedCount(Filter_DominatorOnly) >= 3
                ) {
                    iIndex++;
                    continue;
                }
            }

            case SCHEME_STRICT_THREE_CAP: {
                if (
                    (IsSupportClass(iNextClass) && GetInfectedCount(Filter_SupportOnly) >= 1) ||
                    (IsDominatorClass(iNextClass) && GetInfectedCount(Filter_DominatorOnly) >= 3)
                ) {
                    iIndex++;
                    continue;
                }
            }
        }

        if (iNextClass == SI_CLASS_SPITTER && IsTankInPlay()) {
            MoveClassToEndQueue(SI_CLASS_SPITTER);

            iQueueSize--;

            continue;
        }

        if (GetInfectedCount(Filter_ByClass, iNextClass) >= GetInfectedClassLimit(iNextClass))
        {
            iIndex++;
            continue;
        }


        return iNextClass;
    }

    return SI_CLASS_HUNTER;
}

/**
 * Moves the specified infected class to the end of the spawn queue.
 *
 * If the class is not found in the current queue, no action is taken.
 *
 * @param iInfectedClass   Class identifier to reposition.
 * @return                 True if the class was found and moved, false otherwise.
 */
bool MoveClassToEndQueue(int iInfectedClass)
{
    int iIndex = FindValueInArray(g_hCurrentQueue, iInfectedClass);

    if (iIndex == -1) {
        return false;
    }

    RemoveFromArray(g_hCurrentQueue, iIndex);
    PushArrayCell(g_hCurrentQueue, iInfectedClass);

    return true;
}

typeset Filter
{
    function bool(int iClient);
    function bool(int iClient, any data);
};

/**
 * Returns the number of infected clients that match a given filter.
 *
 * @param filter           A function that determines whether a client should be counted.
 * @param data             Optional custom data passed to the filter.
 * @return                 Number of infected clients passing the filter.
 */
int GetInfectedCount(Filter filter, any data = INVALID_HANDLE)
{
    int iInfectedCount = 0;

    for (int iClient = 1; iClient <= MaxClients; iClient ++)
    {
        if (!IsClientInGame(iClient)
        || !IsClientInfected(iClient)
        || !g_bInfectedWithClass[iClient]) {
            continue;
        }

        bool bPassedFiltering = false;

        Call_StartFunction(INVALID_HANDLE, filter);
        Call_PushCell(iClient);
        Call_PushCell(data);
        Call_Finish(bPassedFiltering);

        if (!bPassedFiltering) {
            continue;
        }

        iInfectedCount ++;
    }

    return iInfectedCount;
}

/**
 * Filter: Matches only support-class infected.
 *
 * @param iClient          Client index to evaluate.
 * @return                 True if client is a support class (Boomer or Spitter).
 */
bool Filter_SupportOnly(int iClient) {
    return IsSupportClass(GetClientInfectedClass(iClient)) && IsPlayerAlive(iClient);
}

/**
 * Filter: Matches only support-class infected.
 *
 * @param iClient          Client index to evaluate.
 * @return                 True if client is a support class (Boomer or Spitter).
 */
bool Filter_SupportOnly_WithDead(int iClient) {
    return IsSupportClass(GetClientInfectedClass(iClient));
}

/**
 * Filter: Matches dominator-class infected.
 *
 * @param iClient          Client index to evaluate.
 * @return                 True if client is a dominator class and alive.
 */
bool Filter_DominatorOnly(int iClient) {
    return IsDominatorClass(GetClientInfectedClass(iClient)) && IsPlayerAlive(iClient);
}

/**
 * Filter: Matches a specific infected class.
 *
 * @param iClient          Client index to evaluate.
 * @param iInfectedClass   Infected class to compare against.
 * @return                 True if client's infected class matches the given one.
 */
bool Filter_ByClass(int iClient, int iInfectedClass) {
    return (GetClientInfectedClass(iClient) == iInfectedClass) && IsPlayerAlive(iClient);
}

/**
 * Returns the ConVar-defined class limit for a given infected class.
 *
 * @param iInfectedClass   Infected class identifier.
 * @return                 Maximum allowed instances of the given class.
 */
int GetInfectedClassLimit(int iInfectedClass)
{
    switch (iInfectedClass)
    {
        case SI_CLASS_SMOKER:  return g_iSmokerLimit;
        case SI_CLASS_BOOMER:  return g_iBoomerLimit;
        case SI_CLASS_JOCKEY:  return g_iJockeyLimit;
        case SI_CLASS_SPITTER: return g_iSpitterLimit;
        case SI_CLASS_HUNTER:  return g_iHunterLimit;
        case SI_CLASS_CHARGER: return g_iChargerLimit;
    }

    return 0;
}

/**
 * Determines whether a given infected class ID is valid and part of the playable pool.
 *
 * @param iInfectedClass    Class identifier to evaluate.
 * @return                  True if class is between SMOKER and CHARGER (inclusive).
 */
bool IsValidInfectedClass(int iInfectedClass) {
    return (iInfectedClass >= SI_CLASS_SMOKER && iInfectedClass <= SI_CLASS_CHARGER);
}

/**
 * Checks whether a given infected class is categorized as a support role.
 *
 * Support classes include Boomer and Spitter.
 *
 * @param iInfectedClass    Class identifier to evaluate.
 * @return                  True if the class is BOOMER or SPITTER.
 */
bool IsSupportClass(int iInfectedClass) {
    return (iInfectedClass == SI_CLASS_BOOMER || iInfectedClass == SI_CLASS_SPITTER);
}

/**
 * Checks whether a given infected class is categorized as a dominator role.
 *
 * Dominator classes are all non-support infected types.
 *
 * @param iInfectedClass    Class identifier to evaluate.
 * @return                  True if class is not a support class.
 */
bool IsDominatorClass(int iInfectedClass)
{
    switch (iInfectedClass)
    {
        case SI_CLASS_SMOKER, SI_CLASS_JOCKEY, SI_CLASS_HUNTER, SI_CLASS_CHARGER: return true;
    }

    return false;
}

/**
 * Retrieves the currently assigned infected class for a client.
 *
 * Uses networked game property `m_zombieClass`.
 *
 * @param iClient           Index of the client.
 * @return                  Client's current infected class.
 */
int GetClientInfectedClass(int iClient) {
    return GetEntProp(iClient, Prop_Send, "m_zombieClass");
}

/**
 * Checks whether the client is in ghost state (waiting to spawn).
 *
 * Uses the `m_isGhost` property from Prop_Send.
 *
 * @param iClient           Index of the client.
 * @return                  True if client is a ghost.
 */
bool IsClientGhost(int iClient) {
    return view_as<bool>(GetEntProp(iClient, Prop_Send, "m_isGhost"));
}

/**
 * Determines whether the client index refers to a valid player entity.
 *
 * @param iClient           Client index to evaluate.
 * @return                  True if index is within 1..MaxClients.
 */
bool IsValidClientIndex(int iClient) {
    return (iClient > 0 && iClient <= MaxClients);
}

/**
 * Checks whether the client is currently playing on the infected team.
 *
 * @param iClient           Index of the client.
 * @return                  True if client's team is TEAM_INFECTED.
 */
bool IsClientInfected(int iClient) {
    return (GetClientTeam(iClient) == TEAM_INFECTED);
}

/**
 * Checks if the current round is the second.
 *
 * @return                  Returns true if is second round, otherwise false.
 */
bool InSecondHalfOfRound() {
    return view_as<bool>(GameRules_GetProp("m_bInSecondHalfOfRound"));
}

/**
 * Inserts a value into an ArrayList at the specified index.
 *
 * This function shifts all elements starting at `iIndex` one position up
 * to make room for the new value, then sets the value at `iIndex`.
 *
 * @param array   Handle to the ArrayList in which to insert the value.
 * @param iIndex  Index at which the value should be inserted.
 *                Valid range is [0, current array size].
 * @param value   Value to insert at the specified index.
 *
 * Note:
 * - If `iIndex` is equal to the array size, the value is appended at the end.
 * - Behavior is undefined if `iIndex` is out of bounds.
 *   Consider adding bounds checking for robustness.
 */
void InsertArrayCell(Handle array, int iIndex, any value)
{
    ShiftArrayUp(array, iIndex);
    SetArrayCell(array, iIndex, value);
}

/**
 * Randomizes the order of elements in an ArrayList using the Fisher-Yates shuffle.
 *
 * @param hArray Handle to the ArrayList to shuffle.
 * @param iStart (Optional) Index to begin shuffling from. Defaults to 0.
 * @param iEnd   (Optional) Index to stop shuffling at. Defaults to last index.
 *               If iEnd is out of bounds or not set, it's clamped to the array size.
 */
void ShuffleArray(Handle hArray, int iStart = 0, int iEnd = -1)
{
    int iArraySize = GetArraySize(hArray);

    if (iEnd == -1 || iEnd > iArraySize - 1) {
        iEnd = iArraySize - 1;
    }

    if (iStart >= iEnd || iStart < 0 || iEnd < 0) {
        return;
    }

    for (int i = iEnd; i > iStart; i--)
    {
        int j = GetRandomInt(iStart, i);

        int a = GetArrayCell(hArray, i);
        int b = GetArrayCell(hArray, j);

        SetArrayCell(hArray, i, b);
        SetArrayCell(hArray, j, a);
    }
}
