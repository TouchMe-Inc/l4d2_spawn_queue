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
	description = "Changed Infected Spawn Behavior",
	version = "build0004",
	url = "https://github.com/TouchMe-Inc/l4d2_vs_spawn_queue"
}


// Queue
#define FIRST                   0
#define CURRENT                 1
#define TYPES                   2

// Size
#define ORDER_SIZE              6
#define TEAM_SIZE               4

// Gamemode
#define GAMEMODE_VERSUS         "versus"
#define GAMEMODE_VERSUS_REALISM "mutation12"

// Team
#define TEAM_SURVIVOR           2
#define TEAM_INFECTED           3

// Infected Class
#define SI_CLASS_SMOKER         1
#define SI_CLASS_BOOMER         2
#define SI_CLASS_SPITTER        4
#define SI_CLASS_CHARGER        6
#define SI_CLASS_TANK           8

// Sugar
#define SetClientClass          L4D_SetClass
#define OnSpawnSpecial          L4D_OnSpawnSpecial
#define IsTankInPlay            L4D2_IsTankInPlay
#define OnEnterGhostState       L4D_OnEnterGhostState
#define OnMaterializeFromGhost  L4D_OnMaterializeFromGhost
#define GetResourceEntity       L4D_GetResourceEntity


int
	g_iSpawnQueue[TYPES][ORDER_SIZE], /**< Starting and game queue */
	g_iSpawnScheme = 0,
	g_iResourceEntity = -1; /**< Find on Map or -1 */

bool
	g_bRoundIsLive = false,
	g_bGamemodeAvailable = false, /**< Only versus mode */
	g_bClientAttack2[MAXPLAYERS] = {false, ...};

ConVar
	g_cvGameMode = null, /**< mp_gamemode */
	g_cvVsSpawnCheme = null;

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

	RegPluginLibrary("vs_spawn_queue");

	return APLRes_Success;
}

int Native_GetClassFromQueue(Handle hPlugin, int iParams)
{
	int iItem = GetNativeCell(1);

	if (0 < iItem || iItem >= ORDER_SIZE) {
		ThrowNativeError(SP_ERROR_NATIVE, "The queue consists of six elements");
	}

	return GetClassFromQueue(iItem);
}

public void OnPluginStart()
{
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_left_safe_area", Event_PlayerLeftSafeArea, EventHookMode_PostNoCopy);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);

	HookConVarChange((g_cvGameMode = FindConVar("mp_gamemode")), OnGamemodeChanged);
	HookConVarChange(
	   (g_cvVsSpawnCheme = CreateConVar(
			.name = "sm_vs_spawn_cheme",
			.defaultValue = "1",
			.description = "\
				0 - The queue is made up of the order of deaths;\
				1 - Coming Soon\
			"
		)),
		OnSpawnSchemeChanged
	);

	char sGameMode[16];
	GetConVarString(g_cvGameMode, sGameMode, sizeof(sGameMode));
	g_bGamemodeAvailable = IsVersusMode(sGameMode);
	g_iSpawnScheme = GetConVarInt(g_cvVsSpawnCheme);
}

public void OnMapStart()
{
	g_iResourceEntity = GetResourceEntity();
	g_bRoundIsLive = false;

	ResetFirstQueue();
	PrepareFirstQueue();
	SyncWithFirstQueue();
}

/**
 * Called when gamemode value is changed.
 */
public void OnGamemodeChanged(ConVar hConVar, const char[] sOldValue, const char[] sNewValue) {
	g_bGamemodeAvailable = IsVersusMode(sNewValue);
}

/**
 * Called when spawn cheme value is changed.
 */
public void OnSpawnSchemeChanged(ConVar hConVar, const char[] sOldValue, const char[] sNewValue) {
	g_iSpawnScheme = GetConVarInt(hConVar);
}

/**
 * Called when the map has loaded, servercfgfile (server.cfg) has been executed, and all
 * plugin configs are done executing. This will always be called once and only once per map.
 * It will be called after OnMapStart().
*/
public void OnConfigsExecuted()
{
	char sGameMode[16];
	GetConVarString(g_cvGameMode, sGameMode, sizeof(sGameMode));
	g_bGamemodeAvailable = IsVersusMode(sGameMode);
}

public Action Event_RoundStart(Event event, char[] name, bool dontBroadcast)
{
	if (g_bGamemodeAvailable == false) {
		return Plugin_Continue;
	}

	g_bRoundIsLive = false;

	return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, char[] name, bool dontBroadcast)
{
	if (g_bGamemodeAvailable == false) {
		return Plugin_Continue;
	}

	if (g_bRoundIsLive == true) {
		g_bRoundIsLive = false;
	} else {
		SyncWithFirstQueue();
	}

	return Plugin_Continue;
}

public Action Event_PlayerLeftSafeArea(Event event, char[] name, bool dontBroadcast)
{
	if (g_bGamemodeAvailable == false) {
		return Plugin_Continue;
	}

	g_bRoundIsLive = true;

	return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (g_bGamemodeAvailable == false || !g_bRoundIsLive) {
		return Plugin_Continue;
	}

	int iClient = GetClientOfUserId(event.GetInt("userid"));

	if (!IsValidClient(iClient)
	|| !IsClientInfected(iClient)) {
		return Plugin_Continue;
	}

	int iZombieClass = GetClientClass(iClient);

	if (!IsValidClass(iZombieClass)) {
		return Plugin_Continue;
	}

	MoveClassToEndQueue(iZombieClass);

	return Plugin_Continue;
}

public void OnEnterGhostState(int iClient)
{
	if (g_bGamemodeAvailable == false || !IsClientGhost(iClient)) {
		return;
	}

	bool bIsPlayerWasAlive = IsPlayerWasAlive(iClient);

	if (!bIsPlayerWasAlive /**< The player has just joined */
	|| GetClientLastTeam(iClient) == TEAM_SURVIVOR /**< Transferred from the Survivor Team */
	|| (IsTankInPlay() && bIsPlayerWasAlive && IsPlayerWasTank(iClient))) { /**< Was Tank and lost control */
		SetClientClass(iClient, GetNextClassFromQueue());
	}
}

public void OnMaterializeFromGhost(int iClient)
{
	if (g_bGamemodeAvailable == false
	|| !g_bRoundIsLive
	|| !IsValidClient(iClient)
	|| !IsClientInGame(iClient)
	|| !IsClientInfected(iClient)) {
		return;
	}

	MoveClassToEndQueue(GetClientClass(iClient));
}

public Action OnSpawnSpecial(int &iZombieClass, const float vecPos[3], const float vecAng[3])
{
	if (g_bGamemodeAvailable == false || !g_bRoundIsLive) {
		return Plugin_Handled;
	}

	MoveClassToEndQueue(iZombieClass = GetNextClassFromQueue());

	return Plugin_Changed;
}

int GetInfectedCountByClass(int iClass)
{
	int iInfectedCount = 0;

	for (int iClient = 1; iClient <= MaxClients; iClient ++)
	{
		if (!IsClientInGame(iClient)
		|| !IsClientInfected(iClient)
		|| (!IsClientGhost(iClient) && !IsPlayerAlive(iClient))
		|| GetClientClass(iClient) != iClass) {
			continue;
		}

		iInfectedCount ++;
	}

	return iInfectedCount;
}

int GetSupportCount()
{
	int iSupportCount = 0;

	for (int iClient = 1; iClient < MaxClients; iClient ++)
	{
		if (!IsClientInGame(iClient)
		|| !IsClientInfected(iClient)
		|| (!IsClientGhost(iClient) && !IsPlayerAlive(iClient))
		|| !IsSupportClass(GetClientClass(iClient))) {
			continue;
		}

		iSupportCount ++;
	}

	return iSupportCount;
}

public Action OnPlayerRunCmd(int iClient, int &iButtons, int &iImpulse, float vVel[3], float vAngles[3], int &iWeapon)
{
	if (g_bGamemodeAvailable == false
	|| !IsTankInPlay()
	|| !IsClientInfected(iClient)
	|| !IsClientGhost(iClient)
	|| GetSupportCount() > 1) {
		return Plugin_Continue;
	}

	// Player was holding m2, and now isn't. (Released)
	if (iButtons & IN_ATTACK2 != IN_ATTACK2 && g_bClientAttack2[iClient]) {
		g_bClientAttack2[iClient] = false;
	}

	// Player was not holding m2, and now is. (Pressed)
	if (iButtons & IN_ATTACK2 == IN_ATTACK2 && !g_bClientAttack2[iClient])
	{
		g_bClientAttack2[iClient] = true;

		int iZombieClass = GetClientClass(iClient);

		switch (iZombieClass)
		{
			case SI_CLASS_BOOMER:
			{
				SetClientClass(iClient, SI_CLASS_SPITTER);
				PrintHintText(iClient, "Press <Mouse2> to change back to <Boomer>.");
			}

			case SI_CLASS_SPITTER:
			{
				SetClientClass(iClient, SI_CLASS_BOOMER);
				PrintHintText(iClient, "Press <Mouse2> to change back to <Spitter>.");
			}
		}

		MoveClassToEndQueue(SI_CLASS_BOOMER);
		MoveClassToEndQueue(SI_CLASS_SPITTER);
	}

	return Plugin_Continue;
}

void ResetFirstQueue()
{
	for (int iItem = 0; iItem < ORDER_SIZE; iItem ++)
	{
		g_iSpawnQueue[FIRST][iItem] = -1;
	}
}

void PrepareFirstQueue()
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

void SyncWithFirstQueue()
{
	for (int iItem = 0; iItem < ORDER_SIZE; iItem ++)
	{
		g_iSpawnQueue[CURRENT][iItem] = g_iSpawnQueue[FIRST][iItem];
	}
}

int GetClassFromQueue(int iItem) {
	return g_iSpawnQueue[CURRENT][iItem];
}

int GetNextClassFromQueue()
{
	int iClass = -1;

	// If the tank is alive, then we skip the spitter and put it at the end of the queue.
	if (IsTankInPlay()) {
		MoveClassToEndQueue(SI_CLASS_SPITTER);
	}

	for (int iItem = 0; iItem < ORDER_SIZE; iItem ++)
	{
		int iTempClass = GetClassFromQueue(iItem);

		if (GetInfectedCountByClass(iTempClass) > 0) {
			continue;
		}

		//if (g_iSpawnScheme == 1
		//&& IsSupportClass(iTempClass)
		//&& GetSupportCount() >= 1) {
		//	continue;
		//}

		iClass = iTempClass;
		break;
	}

	return iClass;
}

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

bool IsValidClass(int iClass) {
	return (iClass >= SI_CLASS_SMOKER && iClass <= SI_CLASS_CHARGER);
}

bool IsSupportClass(int iClass) {
	return iClass == SI_CLASS_BOOMER || iClass == SI_CLASS_SPITTER;
}

int GetClientClass(int iClient) {
	return GetEntProp(iClient, Prop_Send, "m_zombieClass");
}

bool IsClientGhost(int iClient) {
	return view_as<bool>(GetEntProp(iClient, Prop_Send, "m_isGhost"));
}

bool IsValidClient(int iClient) {
	return (iClient > 0 && iClient <= MaxClients);
}

bool IsClientInfected(int iClient) {
	return (GetClientTeam(iClient) == TEAM_INFECTED);
}

int GetClientLastClass(int iClient) {
	return GetEntProp(g_iResourceEntity, Prop_Send, "m_zombieClass", .element = iClient);
}

int GetClientLastTeam(int iClient) {
	return GetEntProp(g_iResourceEntity, Prop_Send, "m_iTeam",.element = iClient);
}

bool IsPlayerWasAlive(int iClient) {
	return view_as<bool>(GetEntProp(g_iResourceEntity, Prop_Send, "m_bAlive", .element = iClient));
}

bool IsPlayerWasTank(int iClient) {
	return (GetClientLastClass(iClient) == SI_CLASS_TANK);
}

/**
 * Is the game mode versus.
 *
 * @param sGameMode         A string containing the name of the game mode.
 *
 * @return                  Returns true if verus, otherwise false.
 */
bool IsVersusMode(const char[] sGameMode) {
	return (StrEqual(sGameMode, GAMEMODE_VERSUS, false)
	|| StrEqual(sGameMode, GAMEMODE_VERSUS_REALISM, false));
}
