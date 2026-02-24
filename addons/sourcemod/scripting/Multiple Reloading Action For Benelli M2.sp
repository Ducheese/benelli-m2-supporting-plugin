/**
 * 因为m_reloadState这一新属性的存在，所以对插件进行重写：
 * √. 首先，实现xm1014从7到8发的上弹 -> 7到8发实现了，但多了两个时间参，9发只能靠空仓换弹；
 * 2. 其次，如果实际clipsize为8，可以主动上弹到9发 -> 被放弃的改进点，最好还是实现一下；
 * √. 其次，实现霰弹枪的弹膛+1动作 -> 通过改timer的时间值，姑且算实现了子弹数变化与动作的同步；
 * √. 其次，需要阻止9以上的重复换弹 -> 现在只要设置m_reloadState为0就行了，很好解决；
 * √. 其次，实现按住左键时能触发空仓检视 -> 有可能做不了，因为reload start动作不可控 -> 最后解决的很完美；
 * 6. 其次，适配机瞄插件；
 * 7. 最后，支持外部配置文件。
 */

//========================================================================================
// DEFINES
//========================================================================================

#define VERSION             "1.0"

#define PARAMCOUNT           11
#define LINELIMIT            256

#define START                1
#define LOOP                 2
#define END                  3

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

int WeaponCount = 0;

/**
 * <xm1014><7><8><0.5333><0.4><0><6><7><1.2><0.4><0.72>
 * 
 * <武器名>
 * <默认clipsize>：xm是7，m3是8，如果父武器是xm写7，是m3写8，反正只能写7和8这两个值
 * <实际clipsize>：武器脚本里填写的实际clipszie
 * <子弹更新时间参>
 * <结束动作时间参>：比子弹更新时间参值略小，调整直到reload_end动作看着舒服为止
 * <idle序列号>
 * <reload_end序列号>
 * <reloade_chamber序列号>
 * <reloade_chamber时间参>
 * <reloade_start时间参>
 * <reloade_loop时间参>
 */

char WeaponNames[256][32];         // 最多支持256把加枪武器，类名最多32个字符
int DefaultClipsize[256] = {0};
int ActualClipsize[256] = {0};

float BulletUpdateTime[256] = {0.0};
float BulletUpdateTime2[256] = {0.0};

int IdleSequence[256] = {0};
int ReloadEndSequence[256] = {0};
int ReloadeChamberSequence[256] = {0};

float ReloadeChamberTime[256] = {0.0};
float ReloadeStartTime[256] = {0.0};
float ReloadeLoopTime[256] = {0.0};

int StartClip[MAXPLAYERS+1] = {-1};     // 记录换弹开始时clip的子弹数，-1代表未记录

Handle TimerTask[MAXPLAYERS+1] = {INVALID_HANDLE};       // 更新子弹数
Handle TimerTask2[MAXPLAYERS+1] = {INVALID_HANDLE};      // 独立处理的reload end动作
Handle TimerTask3[MAXPLAYERS+1] = {INVALID_HANDLE};      // reloade的end

Handle RepeatTask[MAXPLAYERS+1] = {INVALID_HANDLE};      // reloade的loop
Handle RepeatTask2[MAXPLAYERS+1] = {INVALID_HANDLE};     // 用来检测是否按住左键，如果有按住就不进入空仓换弹流程，允许播放空仓检视动作，直到松开为止

//========================================================================================
//========================================================================================

public Plugin myinfo =
{
    name = "Multiple Reloading Action For Tube-Fed Shotgun",
    author = "Ducheese",
    description = "<- Description ->",
    version = VERSION,
    url = "https://space.bilibili.com/1889622121"
}

public void OnPluginStart()
{
    HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Pre);
}

public void OnMapStart()
{
    LoadConfig("configs/MultipleReloadingAction For TubeFed.txt");
}

//========================================================================================
// HOOK
//========================================================================================

public void Event_WeaponFire(Handle event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));

    StartClip[client] = -1;  // 重置StartClip

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

    if (TimerTask3[client] != INVALID_HANDLE)
    {
        CloseHandle(TimerTask3[client]);
        TimerTask3[client] = INVALID_HANDLE;
    }

    if (RepeatTask[client] != INVALID_HANDLE)
    {
        CloseHandle(RepeatTask[client]);
        RepeatTask[client] = INVALID_HANDLE;
    }
}

//========================================================================================
// 用户行为
//========================================================================================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (IsValidClient(client, true))
    {
        int myweapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (myweapon != -1)
        {
            int index = GetWeaponIndex(myweapon);
            
            if (index != -1)
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
                
                // 避免和空仓换弹、空仓检视相互干扰
                if (TimerTask3[client] != INVALID_HANDLE
                || RepeatTask[client] != INVALID_HANDLE
                || RepeatTask2[client] != INVALID_HANDLE)
                    return Plugin_Continue;
                
                // 已经膛内+1了（如果实际clipsize小于默认clipsize的情况，能走这里停下就好了）
                if (clip > ActualClipsize[index])
                {
                    SetEntProp(myweapon, Prop_Send, "m_reloadState", 0);
                    buttons &= ~IN_RELOAD;
                }
                
                // 没有满，但也没有在换弹，直接退出
                if (GetEntProp(myweapon, Prop_Send, "m_reloadState") == 0)
                    return Plugin_Continue;

                // 确实在换弹流程，且刚开始
                if (StartClip[client] == -1)
                    StartClip[client] = clip;
        
                // 如果默认clipsize是7 xm1014
                if (DefaultClipsize[index] == 7 && clip >= 7)
                {
                    // 没有满，且备弹有余，强制发起或者说继续换弹动作
                    if (clip < ActualClipsize[index] && ammo > 0)
                    {
                        // 下面这两行代码放一起就可以反复播放换弹动作但不会更新子弹数
                        SetEntProp(myweapon, Prop_Send, "m_reloadState", 1);
                        buttons |= IN_RELOAD;

                        // 手动更新子弹数，这个参数设置有问题，reload start和loop的耗时不同
                        if (TimerTask[client] == INVALID_HANDLE)
                        {
                            int data = (myweapon << 16) | client;
                            TimerTask[client] = CreateTimer(BulletUpdateTime[index], Timer_UpdateClip, data);
                        }
                    }

                    // 等于实际clipsize了（暂时不考虑换弹到9的情况），处理收尾动作
                    if (clip == ActualClipsize[index])
                    {
                        if (StartClip[client] == ActualClipsize[index] - 1)
                        {
                            if (TimerTask2[client] == INVALID_HANDLE)
                                TimerTask2[client] = CreateTimer(BulletUpdateTime2[index], Timer_ReloadEndAnim, client);
                        }
                        else
                        {
                            SetSequence(client, ReloadEndSequence[index], 9999);
                            SetEntProp(myweapon, Prop_Send, "m_reloadState", 0);
                            StartClip[client] = -1;  // 重置StartClip
                        }
                    }
                }
                // 如果默认clipsize是8 m3
                else if (DefaultClipsize[index] == 8)
                {
                    
                }
            }
        }
    }

    return Plugin_Continue;
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
    int index = GetWeaponIndex(weapon);

    if (index != -1)
    {
        SDKUnhook(weapon, SDKHook_ReloadPost, OnWeaponReload);   // 防止钩子会重复，另外实体被销毁后，钩子会自动解除
        SDKHook(weapon, SDKHook_ReloadPost, OnWeaponReload);
    }
}

public Action OnWeaponReload(int weapon)
{
    int index = GetWeaponIndex(weapon);
    
    if (index != -1)
    {
        int client = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");

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
         * 延时0.1秒再设置m_flNextAttack，没想到就避开了检视插件的检测，解决了
         */
        int buttons = GetEntProp(client, Prop_Data, "m_nButtons");

        if (buttons&IN_ATTACK)
        {
            SetSequence(client, IdleSequence[index], 9999);
            
            if (RepeatTask2[client] == INVALID_HANDLE)
                RepeatTask2[client] = CreateTimer(0.1, Timer_CheckHoldingButton, client, TIMER_REPEAT);
        }
        else
        {
            /**
             * 如果不阻止开火的话，OnWeaponReload就有可能重复执行
             * m_flNextPrimaryAttack比m_flNextAttack的强制力弱不少，长按左键时就是会反复播放start和end动作，下面这段会反复执行很多次
             * 空仓部分用这个更好，因为不影响检视
             */
            SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", GetGameTime() + 9999.0);

            SetSequence(client, ReloadeChamberSequence[index] + START, 9999);  // 要求四个序列紧挨着

            CreateTimer(ReloadeStartTime[index], Timer_ReloadeChamberAnim, client);
        }
    }
    
    return Plugin_Continue;
}

//========================================================================================
// TIMER 空仓换弹相关 需要IsValidClient
//========================================================================================

public Action Timer_ReloadeChamberAnim(Handle timer, int client)
{
    if (IsValidClient(client, true))
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (weapon != -1)
        {
            int index = GetWeaponIndex(weapon);
            
            if (index != -1)
            {
                int ammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));
                int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");

                SetEntProp(weapon, Prop_Send, "m_iClip1", clip + 1);
                SetEntProp(client, Prop_Data, "m_iAmmo", ammo - 1, 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));

                SetSequence(client, ReloadeChamberSequence[index], 9999);

                if (ammo - 1 == 0)
                    TimerTask3[client] = CreateTimer(ReloadeChamberTime[index], Timer_ReloadeEndAnim, client);    // 装填一发就结束
                else
                    CreateTimer(ReloadeChamberTime[index], Timer_StartReloadeLoopAnim, client);    // 继续loop
            }
        }
    }

    return Plugin_Continue;
}

public Action Timer_StartReloadeLoopAnim(Handle timer, int client)
{
    if (IsValidClient(client, true))
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (weapon != -1)
        {
            int index = GetWeaponIndex(weapon);
            
            if (index != -1)
            {
                int ammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));
                int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");

                SetEntProp(weapon, Prop_Send, "m_iClip1", clip + 1);
                SetEntProp(client, Prop_Data, "m_iAmmo", ammo - 1, 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));

                SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", GetGameTime() + 0.0);

                SetSequence(client, ReloadeChamberSequence[index] + LOOP, 9999);
                RepeatTask[client] = CreateTimer(ReloadeLoopTime[index], Timer_ReloadeLoopAnim, client, TIMER_REPEAT);
            }
        }
    }
    
    return Plugin_Continue;
}

public Action Timer_ReloadeLoopAnim(Handle timer, int client)
{
    if (IsValidClient(client, true))
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (weapon != -1)
        {
            int index = GetWeaponIndex(weapon);
            
            if (index != -1)
            {
                int ammo = GetEntProp(client, Prop_Data, "m_iAmmo", 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));
                int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");

                if (ammo > 0 && clip < ActualClipsize[index] + 1)     // 允许膛内+1的地方
                {
                    SetEntProp(weapon, Prop_Send, "m_iClip1", clip + 1);
                    SetEntProp(client, Prop_Data, "m_iAmmo", ammo - 1, 4, GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"));

                    SetSequence(client, ReloadeChamberSequence[index] + LOOP, 9999);

                    return Plugin_Continue;
                }
                else
                {
                    TimerTask3[client] = CreateTimer(0.0, Timer_ReloadeEndAnim, client);
                }
            }
        }
    }

    KillTimer(timer);
    RepeatTask[client] = INVALID_HANDLE;

    return Plugin_Stop;
}

public Action Timer_ReloadeEndAnim(Handle timer, int client)
{
    if (IsValidClient(client, true))
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (weapon != -1)
        {
            int index = GetWeaponIndex(weapon);
            
            if (index != -1)
            {
                SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", GetGameTime() + 0.0);

                SetSequence(client, ReloadeChamberSequence[index] + END, 9999);
            }
        }
    }

    KillTimer(timer);
    TimerTask3[client] = INVALID_HANDLE;

    return Plugin_Continue;
}

//========================================================================================
// TIMER 其它
//========================================================================================

public Action Timer_CheckHoldingButton(Handle timer, int client)
{
    if (IsValidClient(client, true))
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (weapon != -1)
        {
            int index = GetWeaponIndex(weapon);
            
            if (index != -1)
            {
                int buttons = GetEntProp(client, Prop_Data, "m_nButtons");

                if (buttons&IN_ATTACK)
                {
                    // 检测到长按左键
                    SetEntPropFloat(client, Prop_Data, "m_flNextAttack", GetGameTime() + 9999.0);

                    return Plugin_Continue;
                }
                else
                {
                    // 已松开左键，允许换弹
                    SetEntPropFloat(client, Prop_Data, "m_flNextAttack", GetGameTime() + 0.0);
                }
            }
        }
    }

    KillTimer(timer);
    RepeatTask2[client] = INVALID_HANDLE;

    return Plugin_Stop;
}

public Action Timer_UpdateClip(Handle timer, int data)
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

public Action Timer_ReloadEndAnim(Handle timer, int client)
{
    StartClip[client] = -1;  // 重置StartClip

    if (IsValidClient(client, true))
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        if (weapon != -1)
        {
            int index = GetWeaponIndex(weapon);
            
            if (index != -1)
            {
                SetSequence(client, ReloadEndSequence[index], 9999);
                SetEntProp(weapon, Prop_Send, "m_reloadState", 0);
            }
        }
    }

    KillTimer(timer);
    TimerTask2[client] = INVALID_HANDLE;

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

    // 下面这个是必要的，否则正常loop也会想插进来播放
    // 说实话这个时间值计算就不合理，但只有这样播放才是正确的
    int weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
    if (weapon != -1)
        SetEntPropFloat(weapon, Prop_Data, "m_flTimeWeaponIdle", GetGameTime() + float(frame));
}

int GetWeaponIndex(int weapon)
{
    char classname[32];
    GetEdictClassname(weapon, classname, sizeof(classname));
    ReplaceString(classname, strlen(classname), "weapon_", "");

    int index = -1;
    for (int i = 1; i <= WeaponCount; i++)
    {
        if (StrEqual(classname, WeaponNames[i], false))
        {
            index = i;
            break;
        }
    }

    return index;
}

void LoadConfig(char[] PATH)
{
    char filepath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, filepath, sizeof(filepath), PATH);
    Handle hfile = OpenFile(filepath, "r");

    if (hfile != INVALID_HANDLE)
    {
        char fileline[LINELIMIT];             // 每行最多256个字符
        char data[PARAMCOUNT][LINELIMIT];     // 共PARAMCOUNT个参数，为了对齐字符数也写了256，虽然很浪费

        while (ReadFileLine(hfile, fileline, LINELIMIT))
        {
            // 开头结尾漏写括号倒是无妨，中间漏写就不行了，会被直接跳过
            // 如果括号写多了一组，最后一组会被无视掉，也就是截断掉
            if (ExplodeString(fileline, "><", data, PARAMCOUNT, LINELIMIT) == PARAMCOUNT)        // 把fileline按><分部分放进data里
            {
                for (int i = 0; i < PARAMCOUNT; i++)
                {
                    TrimString(data[i]);     // 修剪所有字符串空格
                }

                if (strlen(data[0]) > 0)
                    ReplaceString(data[0], strlen(data[0]), "<", "");                            // 去掉最开头的<
                if (strlen(data[PARAMCOUNT-1]) > 0)
                    ReplaceString(data[PARAMCOUNT-1], strlen(data[PARAMCOUNT-1]), ">", "");      // 去掉最尾巴的>

                // 该进行合法性检验了，合法的才可以WeaponCount++，要求填的值不可以让插件报错
                // data 0 是文本
                if (strlen(data[0]) == 0)
                    continue;

                // data 1 是整数，且只能填7或8
                if (StringToInt(data[1]) != 7 && StringToInt(data[1]) != 8)
                    continue;

                // data 2 是整数，必须大于等于0
                if (StringToInt(data[2]) < 0)
                    continue;

                // data 3 和 4 是浮点数，都必须大于0
                if (StringToFloat(data[3]) <= 0.0 || StringToFloat(data[4]) <= 0.0)
                    continue;

                // data 5 和 6 和 7是整数，必须大于等于0
                if (StringToInt(data[5]) < 0 || StringToInt(data[6]) < 0 || StringToInt(data[7]) < 0)
                    continue;

                // data 8 和 9 和 10是浮点数，都必须大于0
                if (StringToFloat(data[8]) <= 0.0 || StringToFloat(data[9]) <= 0.0 || StringToFloat(data[10]) <= 0.0)
                    continue;

                // 确认合法，至少后面不会报错
                WeaponCount++;
                
                strcopy(WeaponNames[WeaponCount], strlen(data[0])+1, data[0]);
                DefaultClipsize[WeaponCount] = StringToInt(data[1]);
                ActualClipsize[WeaponCount] = StringToInt(data[2]);

                BulletUpdateTime[WeaponCount] = StringToFloat(data[3]);
                BulletUpdateTime2[WeaponCount] = StringToFloat(data[4]);

                IdleSequence[WeaponCount] = StringToInt(data[5]);
                ReloadEndSequence[WeaponCount] = StringToInt(data[6]);
                ReloadeChamberSequence[WeaponCount] = StringToInt(data[7]);

                ReloadeChamberTime[WeaponCount] = StringToFloat(data[8]);
                ReloadeStartTime[WeaponCount] = StringToFloat(data[9]);
                ReloadeLoopTime[WeaponCount] = StringToFloat(data[10]);
            }
        }

        delete hfile;    // 避免句柄泄露
    }
}

//========================================================================================
// STOCK
//========================================================================================

stock bool IsValidClient(int client, bool bAlive = false)
{
    return (client >= 1 && client <= MaxClients && IsClientInGame(client) && !IsClientSourceTV(client) && (!bAlive || IsPlayerAlive(client)));
}
