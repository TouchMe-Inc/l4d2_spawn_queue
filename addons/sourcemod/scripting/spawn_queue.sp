#pragma semicolon               1
#pragma newdecls                required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <colors>


public Plugin myinfo =
{
	name = "VersusSpawnQueue",
	author = "TouchMe",
	description = "The plugin sets the queue of infected in the order of their death",
	version = "build0010",
	url = "https://github.com/TouchMe-Inc/l4d2_spawn_queue"
}


#define TRANSLATIONS            "spawn_queue.phrases"

/*
 * Queue.
 */
#define FIRST                   0
#define CURRENT                 1

/*
 * Size.
 */
#define TYPE_SIZE               2
#define ORDER_SIZE              6

/*
 * Scheme.
 */
#define SCHEME_QUAD             0
#define SCHEME_NO_QUAD          1

/*
 * Team.
 */
#define TEAM_SURVIVOR           2
#define TEAM_INFECTED           3

/*
 * Infected Class.
 */
#define SI_CLASS_SMOKER         1
#define SI_CLASS_BOOMER         2
#define SI_CLASS_SPITTER        4
#define SI_CLASS_CHARGER        6
#define SI_CLASS_TANK           8

/*
 * Sugar for left4dhooks.
 */
#define SetClientClass          L4D_SetClass
#define OnSpawnSpecial          L4D_OnSpawnSpecial
#define OnSpawnSpecial_Post     L4D_OnSpawnSpecial_Post
#define IsTankInPlay            L4D2_IsTankInPlay
#define OnEnterGhostState       L4D_OnEnterGhostState
#define GetResourceEntity       L4D_GetResourceEntity


int
	g_iSpawnScheme = 0, /**< sm_vs_spawn_cheme buffer */
	g_iSpawnQueue[TYPE_SIZE][ORDER_SIZE], /**< Starting and game queue */ 
	g_iResourceEntity = -1; /**< Find on Map or -1 */

bool
	g_bRoundIsLive = false,
	g_bClientAttack2[MAXPLAYERS + 1] = {false, ...};

ConVar g_cvSpawnCheme = null; /**< sm_vs_spawn_cheme */


/**
 * Called before OnPluginStart.
 *
 * @param myself      Handle to the plugin
 * @param bLate       Whether or not the plugin was loaded "late" (after map load)
 * @param sErr        Error message buffer in case load failed
 * @param iErrLen     Maximum number of characters for error message buffer
 * @return            APLRes_Success | APLRes_SilentFailure
 */
public APLRes AskPluginLoad2(Handle myself, bool bLate, char[] sErr, int iErrLen)
{
	EngineVersion engine = GetEngineVersion();

	if (engine != Engine_Left4Dead2)
	{
		strcopy(sErr, iErrLen, "Plugin only supports Left 4 Dead 2");
		return APLRes_SilentFailure;
	}

	CreateNative("GetClassFromQueue", Native_GetClassFromQueue);

	RegPluginLibrary("spawn_queue");

	return APLRes_Success;
}

/**
 * Returning a class from a queue by item.
 */
int Native_GetClassFromQueue(Handle hPlugin, int iParams)
{
	int iItem = GetNativeCell(1);

	if (0 < iItem || iItem >= ORDER_SIZE) {
		ThrowNativeError(SP_ERROR_NATIVE, "The parameter must have a value from 0 to 5");
	}

	return GetClassFromQueue(iItem);
}

/**
 * Called when the plugin is fully initialized and all known external references are resolved.
 */
public void OnPluginStart()
{
	/*
	 * Load translations.
	 */
	LoadTranslations(TRANSLATIONS);

	/*
	 * Hook events.
	 */
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_left_safe_area", Event_PlayerLeftSafeArea, EventHookMode_PostNoCopy);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);

	/*
	 * Console variables.
	 */
	HookConVarChange(
		(g_cvSpawnCheme = CreateConVar(
			.name = "sm_spawn_cheme",
			.defaultValue = "0",
			.description = "The queue is made up of the order of deaths: 0 - With quads; 1 - Without quads"
		)),
		OnSpawnSchemeChanged
	);

	g_iSpawnScheme = GetConVarInt(g_cvSpawnCheme);
}

/**
 * Filling out the first queue for teams.
 */
public void OnMapInit(const char[] sMap)
{
	ResetFirstQueue();
	GenerateFirstQueue();
	SyncWithFirstQueue();
}

/**
 * Finding Resource Entity.
 */
public void OnMapStart() {
	g_iResourceEntity = GetResourceEntity();
}

/**
 * Called when spawn cheme value is changed.
 */
public void OnSpawnSchemeChanged(ConVar hConVar, const char[] sOldValue, const char[] sNewValue) {
	g_iSpawnScheme = GetConVarInt(hConVar);
}

/**
 * Setting the round status.
 */
void Event_RoundStart(Event event, char[] name, bool dontBroadcast) {
	g_bRoundIsLive = false;
}

/**
 * Setting the round status.
 */
void Event_PlayerLeftSafeArea(Event event, char[] name, bool dontBroadcast) {
	g_bRoundIsLive = true;
}

/**
 * Setting the round status.
 */
void Event_RoundEnd(Event event, char[] name, bool dontBroadcast)
{
	if (g_bRoundIsLive == true) {
		g_bRoundIsLive = false;
	} else {
		SyncWithFirstQueue();
	}
}

/**
 * Send all dead infected to the end of the queue.
 */
Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bRoundIsLive) {
		return Plugin_Continue;
	}

	int iClient = GetClientOfUserId(GetEventInt(event, "userid"));

	if (!IsValidClient(iClient) || !IsClientInfected(iClient)) {
		return Plugin_Continue;
	}

	int iZombieClass = GetClientClass(iClient);

	if (!IsValidClass(iZombieClass)) {
		return Plugin_Continue;
	}

	MoveClassToEndQueue(iZombieClass);

	return Plugin_Continue;
}

/**
 * Setting the class of a special infected player.
 */
public void OnEnterGhostState(int iClient)
{
	bool bIsClientWasAlive = IsClientWasAlive(iClient);

	if (!bIsClientWasAlive /*< The player has just joined */
	|| (GetClientLastTeam(iClient) == TEAM_SURVIVOR) /*< Transferred from the Survivor Team */
	|| (IsTankInPlay() && bIsClientWasAlive && IsClientWasTank(iClient))) /*< Was Tank and lost control */
	{
		SetClientClass(iClient, GetNextClassFromQueue(GetClientClass(iClient)));
	}
}

/**
 * Setting the class of a special infected bot.
 */
public Action OnSpawnSpecial(int &iZombieClass, const float vecPos[3], const float vecAng[3])
{
	if (!g_bRoundIsLive) {
		return Plugin_Handled;
	}

	iZombieClass = GetNextClassFromQueue(-1);

	return Plugin_Changed;
}

/**
 * Move to end special infected class for bots.
 */
public void OnSpawnSpecial_Post(int iClient, int iZombieClass, const float vecPos[3], const float vecAng[3])
{
	MoveClassToEndQueue(iZombieClass);
}

/**
 * Switching si class from Boomer to Spitter during the life of the tank.
 * Called when a clients movement buttons are being processed.
 */
public Action OnPlayerRunCmd(int iClient, int &iButtons, int &iImpulse, float vVel[3], float vAngles[3], int &iWeapon)
{
	if (!IsTankInPlay()
	|| !IsClientInfected(iClient)
	|| !IsClientGhost(iClient)
	|| GetInfectedCount(Filter_SupportOnly) > 1) {
		return Plugin_Continue;
	}

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

		switch (GetClientClass(iClient))
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
 * The function prepares the queue to be filled.
 */
void ResetFirstQueue()
{
	for (int iItem = 0; iItem < ORDER_SIZE; iItem ++)
	{
		g_iSpawnQueue[FIRST][iItem] = -1;
	}
}

/**
 * Filling the queue of infected in random order.
 */
void GenerateFirstQueue()
{
	for (int iZombieClass = SI_CLASS_SMOKER; iZombieClass <= SI_CLASS_CHARGER; iZombieClass ++)
	{
		for (;;)
		{
			int iItem = GetRandomInt(0, ORDER_SIZE-1);

			if (IsValidClass(g_iSpawnQueue[FIRST][iItem])) {
				continue;
			}

			g_iSpawnQueue[FIRST][iItem] = iZombieClass;
			break;
		}
	}
}

/**
 * Copy the first queue to the current one.
 */
void SyncWithFirstQueue()
{
	for (int iItem = 0; iItem < ORDER_SIZE; iItem ++)
	{
		g_iSpawnQueue[CURRENT][iItem] = g_iSpawnQueue[FIRST][iItem];
	}
}

/**
 * Returning a class from a queue by item.
 */
int GetClassFromQueue(int iItem) {
	return g_iSpawnQueue[CURRENT][iItem];
}

/**
 *
 */
int GetNextClassFromQueue(int iCurrentClass)
{
	/*
	 * If the tank is alive, then we skip the spitter and put it at the end of the queue.
	 */
	if (IsTankInPlay()) {
		MoveClassToEndQueue(SI_CLASS_SPITTER);
	}

	for (int iItem = 0; iItem < ORDER_SIZE; iItem ++)
	{
		int iNextClass = GetClassFromQueue(iItem);

		if (iNextClass == iCurrentClass) {
			return iNextClass;
		}

		if (GetInfectedCount(Filter_ByClass, iNextClass)) {
			continue;
		}

		return iNextClass;
	}

	return -1;
}

/**
 * Find an element in a queue by its class.
 */
int FindClassInQueue(int iClass)
{
	int iFoundIndex = -1;

	for (int iItem = 0; iItem < ORDER_SIZE; iItem ++)
	{
		if (GetClassFromQueue(iItem) != iClass) {
			continue;
		}

		iFoundIndex = iItem;
		break;
	}

	return iFoundIndex;
}

/**
 * Sends the specified class to the end of the queue.
 */
void MoveClassToEndQueue(int iClass)
{
	int iFoundIndex = FindClassInQueue(iClass);

	if (iFoundIndex == -1) {
		return;
	}

	for (int iItem = iFoundIndex; iItem < (ORDER_SIZE - 1); iItem++)
	{
		g_iSpawnQueue[CURRENT][iItem] = g_iSpawnQueue[CURRENT][iItem + 1];
	}

	g_iSpawnQueue[CURRENT][ORDER_SIZE - 1] = iClass;
}

typeset Filter
{
	function bool(int iClient);
	function bool(int iClient, any data);
};

/**
 *
 */
int GetInfectedCount(Filter filter, any data = INVALID_HANDLE)
{
	int iInfectedCount = 0;

	for (int iClient = 1; iClient <= MaxClients; iClient ++)
	{
		if (!IsClientInGame(iClient) || !IsClientInfected(iClient)) {
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
 *
 */
bool Filter_SupportOnly(int iClient) {
	return IsSupportClass(GetClientClass(iClient));
}

/**
 *
 */
bool Filter_AliveDominatorOnly(int iClient) {
	return IsDominatorClass(GetClientClass(iClient)) && IsPlayerAlive(iClient);
}

/**
 *
 */
bool Filter_ByClass(int iClient, int iClass) {
	return (GetClientClass(iClient) == iClass);
}

/**
 * The class is included in the pool of infected.
 */
bool IsValidClass(int iClass) {
	return (iClass >= SI_CLASS_SMOKER && iClass <= SI_CLASS_CHARGER);
}

/**
 * The class is in the support pool.
 */
bool IsSupportClass(int iClass) {
	return (iClass == SI_CLASS_BOOMER || iClass == SI_CLASS_SPITTER);
}

/**
 * The class is in the dominator pool.
 */
bool IsDominatorClass(int iClass) {
	return (IsSupportClass(iClass) == false);
}

/**
 * Get the zombie player class.
 */
int GetClientClass(int iClient) {
	return GetEntProp(iClient, Prop_Send, "m_zombieClass");
}

/**
 * Returns whether the player is a ghost.
 */
bool IsClientGhost(int iClient) {
	return view_as<bool>(GetEntProp(iClient, Prop_Send, "m_isGhost"));
}

/**
 * Returns whether an entity is a player.
 */
bool IsValidClient(int iClient) {
	return (iClient > 0 && iClient <= MaxClients);
}

/**
 * Returns whether the player is infected.
 */
bool IsClientInfected(int iClient) {
	return (GetClientTeam(iClient) == TEAM_INFECTED);
}

/**
 * Returns whether the player was a Tank.
 */
bool IsClientWasTank(int iClient) {
	return (GetClientLastClass(iClient) == SI_CLASS_TANK);
}

/**
 * Retrieve the previous zombie player class.
 */
int GetClientLastClass(int iClient) {
	return GetEntProp(g_iResourceEntity, Prop_Send, "m_zombieClass", .element = iClient);
}

/**
 * Get player's previous team.
 */
int GetClientLastTeam(int iClient) {
	return GetEntProp(g_iResourceEntity, Prop_Send, "m_iTeam", .element = iClient);
}

/**
 * Returns whether the player was alive.
 */
bool IsClientWasAlive(int iClient) {
	return view_as<bool>(GetEntProp(g_iResourceEntity, Prop_Send, "m_bAlive", .element = iClient));
}
