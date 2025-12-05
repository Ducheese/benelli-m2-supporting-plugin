/**
 * 因为m_reloadState这一新属性的存在，所以对插件进行重写：
 * √. 首先，实现xm1014从7到9发的上弹 -> 7到8发就行，9发靠空仓换弹吧；
 * √. 其次，默认clip要求为8，可以通过上弹到9发 -> 和问题1归并到一起，已解决；
 * 3. 其次，实现霰弹枪的弹膛+1动作 -> 通过改timer的时间值，姑且算实现了子弹数变化与动作的同步
 * √. 其次，需要阻止9以上的重复换弹 -> 现在只要设置m_reloadState为0就行了，很好解决；
 * 5. 最后，实现按住左键时能触发空仓检视 -> 有可能做不了，因为reload start动作不可控
 * 
 * 目前挺完美的了。
 */

//========================================================================================
// DEFINES
//========================================================================================

#define VERSION             "1.0" 
#define WEAPONNAME          "weapon_m2" // 武器名字 weapon_m2

#define ANIM_IDLE            0   // 2
#define ANIM_RLD_END         6   // 25
#define ANIM_RLDE_CHAMBER    7   // 39
#define ANIM_RLDE_START      8   // 20
#define ANIM_RLDE_LOOP       9   // 23
#define ANIM_RLDE_END        10  // 22
#define ANIM_INSPECT         12  // 244
#define ANIM_INSPECTE        13  // 232

//========================================================================================
// INCLUDES
//========================================================================================

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

//========================================================================================
// HANDLES & VARIABLES
//========================================================================================

int StartClip = -1;

Handle TimerTask[MAXPLAYERS+1] = INVALID_HANDLE;
Handle TimerTask2[MAXPLAYERS+1] = INVALID_HANDLE;
Handle TimerTask3[MAXPLAYERS+1] = INVALID_HANDLE;

Handle RepeatTask[MAXPLAYERS+1] = INVALID_HANDLE;
Handle RepeatTask2[MAXPLAYERS+1] = INVALID_HANDLE;

//========================================================================================
//========================================================================================

public Plugin myinfo =
{
    name = "Multiple Reloading Action For Benelli M2",
    author = "ducheese",
    description = "<- Description ->",
    version = VERSION,
    url = "https://space.bilibili.com/1889622121"
}

public void OnPluginStart()
{    
    HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Pre);
}

//========================================================================================
// SDKHOOK
//========================================================================================

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_WeaponEquipPost, OnWeaponEquip);
}

public void OnWeaponEquip(int client, int weapon)
{
    if (IsValidClient(client, true))
    {    
        char classname[32];
        GetEdictClassname(weapon, classname, sizeof(classname));

        if (StrEqual(WEAPONNAME, classname))
        {
            SDKUnhook(weapon, SDKHook_ReloadPost, OnWeaponReload);  // 防止钩子会重复
            SDKHook(weapon, SDKHook_ReloadPost, OnWeaponReload);
        }
    }
}

public Action OnWeaponReload(int weapon)   // 如果不阻止开火的话，就有可能重复执行
{
    int client = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");

    if (IsValidClient(client, true))
    {
        char classname[32];
        GetEdictClassname(weapon, classname, sizeof(classname));
        
        if (StrEqual(WEAPONNAME, classname))
        {
            int ammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));
            int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
            
            // 备弹量为0时不触发
            if (ammo <= 0)
                return Plugin_Handled;
            
            // 非空仓且不满弹不触发
            if (clip > 0)
                return Plugin_Handled;

            /**
             * 打空子弹并长按左键时，允许空仓检视
             * 然而空仓检视没法触发，就是这里出问题了
             * 检视插件里规定了“换弹期间禁止检视”，用的是m_flNextAttack减去GetGameTime来算冷冻时间，所以会出问题
             * 
             * m_flNextPrimaryAttack比m_flNextAttack的强制力弱不少，长按左键时就是会反复播放start和end动作，下面这段会反复执行很多次
             * 延时0.1秒再设置m_flNextAttack，没想到就避开了检视插件的检测，解决了
             */
            int buttons = GetEntProp(client, Prop_Data, "m_nButtons");

            if (buttons&IN_ATTACK)
            {
                // PrintToChat(client, "测试是否重复执行");

                SetSequence(client, ANIM_IDLE, 2);
                
                if (RepeatTask2[client] == INVALID_HANDLE)
                    RepeatTask2[client] = CreateTimer(0.1, Timer_CheckButton_Repeat, client, TIMER_REPEAT);
            }
            else
            {
                SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", GetGameTime() + 9999.0);     // 空仓部分用这个更好，因为不影响检视

                SetSequence(client, ANIM_RLDE_START, 20);
                CreateTimer(0.4, Timer_ReloadChamberAnim, client);     // 0.4以上容易有谜之卡顿感
            }
        }        
    }
    
    return Plugin_Continue;
}

//========================================================================================
// HOOK
//========================================================================================

public void Event_WeaponFire(Handle event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));

    if (TimerTask[client] != INVALID_HANDLE)
    {
        CloseHandle(TimerTask[client]);
        TimerTask[client] = INVALID_HANDLE;
    }

    if (TimerTask2[client] != INVALID_HANDLE)
    {
        CloseHandle(TimerTask2[client]);
        TimerTask2[client] = INVALID_HANDLE;
    }

    StartClip = -1;  // 重置StartClip

    if (RepeatTask[client] != INVALID_HANDLE)
    {
        CloseHandle(RepeatTask[client]);
        RepeatTask[client] = INVALID_HANDLE;
    }

    if (TimerTask3[client] != INVALID_HANDLE)
    {
        CloseHandle(TimerTask3[client]);
        TimerTask3[client] = INVALID_HANDLE;
    }
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (IsValidClient(client, true))
    {
        int myweapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (myweapon > -1)
        {
            char classname[32];
            GetEdictClassname(myweapon, classname, sizeof(classname));
            
            if (StrEqual(WEAPONNAME, classname))
            {
                int ammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, GetEntProp(myweapon, Prop_Data, "m_iPrimaryAmmoType"));
                int clip = GetEntProp(myweapon, Prop_Send, "m_iClip1");

                /**
                 * 似乎m_reloadState不为0，就代表处于换弹的过程，和检查InReload可能差不多
                 * 
                 * 上弹期间，m_reloadState可能值为1或2：
                 * 1. 强制设1会发起换弹动作；
                 * 2. 强制设2会完成子弹数的更新；
                 * 
                 * 其实原版clip和maxclip不一样时，只要长按R键也是可以换弹的
                 * 改button的方法就是基于这个原理，下面这段代码会在短时间内反复执行多次，于是就变成了长按R键
                 * 
                 * 非空仓换弹的子弹数更新间隙为32/60=0.5333秒
                 * 
                 * 如果是从7开始到8，需要延时SetSequence
                 * 如果是从7以下开始，则不需要延时
                 * 
                 * 嗯，效果很好
                 * 
                 * 还得考虑开枪打断的可能性，已经加了相应判断
                 * 
                 * 如果武器脚本的clip是8，那怎么都无法实现从8到9的换弹的，放弃吧
                 */

                // PrintToChat(client, "m_reloadState: %d", GetEntProp(myweapon, Prop_Send, "m_reloadState"));

                if (RepeatTask[client] != INVALID_HANDLE)       // 空仓动作和以下独立开
                    return Plugin_Continue;

                if (clip == 0 && buttons&IN_ATTACK)
                {
                    SetEntProp(myweapon, Prop_Send, "m_reloadState", 0);    // 必要的
                }

                if (StartClip == -1 && GetEntProp(myweapon, Prop_Send, "m_reloadState") > 0)
                {
                    StartClip = clip;
                }

                if (clip == 7 && GetEntProp(myweapon, Prop_Send, "m_reloadState") > 0 && ammo > 0)   // 没考虑备弹
                {
                    // 下面这两行代码放一起就可以反复播放换弹动作但不会更新子弹数
                    SetEntProp(myweapon, Prop_Send, "m_reloadState", 1);
                    buttons |= IN_RELOAD;

                    // 手动更新子弹数
                    if (TimerTask[client] == INVALID_HANDLE)
                    {
                        int data = (myweapon << 16) | client;
                        TimerTask[client] = CreateTimer(0.5333, Timer_UpdateClipAmmo, data);
                    }
                }

                if (clip == 8 && GetEntProp(myweapon, Prop_Send, "m_reloadState") > 0)
                {
                    if (StartClip == 7)
                    {
                        if (TimerTask2[client] == INVALID_HANDLE)
                            TimerTask2[client] = CreateTimer(0.4, Timer_ReloadEndAnim2, client);  // 这个时间可以适当调短，0.53太长了
                    }
                    else
                    {
                        SetSequence(client, ANIM_RLD_END, 25);
                        SetEntProp(myweapon, Prop_Send, "m_reloadState", 0);

                        StartClip = -1;  // 重置StartClip
                    }
                }

                if (clip == 9)
                {
                    // PrintToChat(client, "分支1");

                    SetEntProp(myweapon, Prop_Send, "m_reloadState", 0);
                    buttons &= ~IN_RELOAD;
                }
            }
        }
    }

    return Plugin_Continue;
}

//========================================================================================
// FUCTIONS
//========================================================================================

void SetSequence(int client, int sequence, int frame)
{
    int ent = GetEntPropEnt(client, Prop_Send, "m_hViewModel");

    // if (GetEntProp(ent, Prop_Send, "m_nSequence") == sequence) return;   // 一点用都没有

    SetEntProp(ent, Prop_Send, "m_nSequence", sequence);
    SetEntPropFloat(ent, Prop_Send, "m_flPlaybackRate", 1.0);

    int weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
    if (weapon != -1)
        SetEntPropFloat(weapon, Prop_Data, "m_flTimeWeaponIdle", GetGameTime() + float(frame));     // 说实话这个时间值计算就不合理，但只有这样播放才是正确的
}

//========================================================================================
// TIMER Part1
//========================================================================================

public Action Timer_ReloadChamberAnim(Handle timer, int client)
{
    if (IsValidClient(client, true))
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (weapon > -1)
        {
            char classname[32];
            GetEdictClassname(weapon, classname, sizeof(classname));
            
            if (StrEqual(WEAPONNAME, classname))
            {
                int ammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));
                int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");

                SetEntProp(weapon, Prop_Send, "m_iClip1", clip + 1);
                SetEntProp(client, Prop_Data, "m_iAmmo", ammo - 1, 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));

                SetSequence(client, ANIM_RLDE_CHAMBER, 39);

                if (ammo - 1 == 0)
                    CreateTimer(1.2, Timer_ReloadEndAnim, client);     // 装填一发就结束
                else
                    CreateTimer(1.2, Timer_ReloadLoopAnim, client);    // 1.2感觉很合适，就不改了吧
            }
        }
    }

    return Plugin_Continue;
}

public Action Timer_ReloadLoopAnim(Handle timer, int client)
{
    if (IsValidClient(client, true))
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (weapon > -1)
        {
            char classname[32];
            GetEdictClassname(weapon, classname, sizeof(classname));
            
            if (StrEqual(WEAPONNAME, classname))
            {
                int ammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));
                int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");

                SetEntProp(weapon, Prop_Send, "m_iClip1", clip + 1);
                SetEntProp(client, Prop_Data, "m_iAmmo", ammo - 1, 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));

                SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", GetGameTime() + 0.0);

                SetSequence(client, ANIM_RLDE_LOOP, 23);
                RepeatTask[client] = CreateTimer(0.72, Timer_ReloadLoopAnim_Repeat, client, TIMER_REPEAT);   // 0.71是临界值，0.72以上都会露出一点破绽
            }
        }
    }
    
    return Plugin_Continue;
}

public Action Timer_ReloadLoopAnim_Repeat(Handle timer, int client)
{
    if (IsValidClient(client, true))
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (weapon > -1)
        {
            char classname[32];
            GetEdictClassname(weapon, classname, sizeof(classname));
            
            if (StrEqual(WEAPONNAME, classname))
            {
                int ammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));
                int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");

                if (ammo > 0 && clip < 9)
                {
                    SetEntProp(weapon, Prop_Send, "m_iClip1", clip + 1);
                    SetEntProp(client, Prop_Data, "m_iAmmo", ammo - 1, 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));

                    SetSequence(client, ANIM_RLDE_LOOP, 23);

                    return Plugin_Continue;
                }
                else
                {
                    // PrintToChat(client, "分支2");     // 分支2 -> 分支1 -> 分支3，加了TimerTask3后，变成了231，不对劲

                    TimerTask3[client] = CreateTimer(0.0, Timer_ReloadEndAnim, client);
                }
            }
        }
    }

    KillTimer(timer);
    RepeatTask[client] = INVALID_HANDLE;

    return Plugin_Handled;
}

public Action Timer_ReloadEndAnim(Handle timer, int client)
{
    if (IsValidClient(client, true))
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (weapon > -1)
        {
            char classname[32];
            GetEdictClassname(weapon, classname, sizeof(classname));
            
            if (StrEqual(WEAPONNAME, classname))
            {
                // PrintToChat(client, "分支3");

                SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", GetGameTime() + 0.0);

                SetSequence(client, ANIM_RLDE_END, 22);
            }
        }
    }

    KillTimer(timer);
    TimerTask3[client] = INVALID_HANDLE;

    return Plugin_Continue;
}

//========================================================================================
// TIMER Part2
//========================================================================================

public Action Timer_CheckButton_Repeat(Handle timer, int client)
{
    if (IsValidClient(client, true))
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (weapon > -1)
        {
            char classname[32];
            GetEdictClassname(weapon, classname, sizeof(classname));
            
            if (StrEqual(WEAPONNAME, classname))
            {
                int buttons = GetEntProp(client, Prop_Data, "m_nButtons");

                if (buttons&IN_ATTACK)
                {
                    // PrintToChat(client, "检测到长按左键");

                    SetEntPropFloat(client, Prop_Data, "m_flNextAttack", GetGameTime() + 9999.0);

                    return Plugin_Continue;
                }
                else
                {
                    // PrintToChat(client, "已松开左键，允许换弹");

                    SetEntPropFloat(client, Prop_Data, "m_flNextAttack", GetGameTime() + 0.0);
                }
            }
        }
    }

    KillTimer(timer);
    RepeatTask2[client] = INVALID_HANDLE;

    return Plugin_Handled;
}

public Action Timer_ReloadEndAnim2(Handle timer, int client)
{
    if (IsValidClient(client, true))
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (weapon > -1)
        {
            char classname[32];
            GetEdictClassname(weapon, classname, sizeof(classname));
            
            if (StrEqual(WEAPONNAME, classname))
            {
                SetSequence(client, ANIM_RLD_END, 25);
                SetEntProp(weapon, Prop_Send, "m_reloadState", 0);
            }
        }
    }

    StartClip = -1;  // 重置StartClip

    KillTimer(timer);
    TimerTask2[client] = INVALID_HANDLE;

    return Plugin_Continue;
}

public Action Timer_UpdateClipAmmo(Handle timer, int data)
{
    int client = data & 0xFFFF;
    int weapon = data >> 16;

    int ammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));
    int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");

    SetEntProp(weapon, Prop_Send, "m_iClip1", clip + 1);
    SetEntProp(client, Prop_Data, "m_iAmmo", ammo - 1, 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));

    KillTimer(timer);
    TimerTask[client] = INVALID_HANDLE;

    return Plugin_Continue;
}

//========================================================================================
// STOCK
//========================================================================================

stock bool IsValidClient(int client, bool bAlive = false)
{
    return (client >= 1 && client <= MaxClients && IsClientInGame(client) && !IsClientSourceTV(client) && (!bAlive || IsPlayerAlive(client)));
}
