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

#define PARAMCOUNT           9
#define LINELIMIT            128

#define START                1   // 要求四个空仓动作序列连续
#define LOOP                 2
#define END                  3

#define XMCLIP               7
#define M3CLIP               8

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
 * <xm1014><7><8><0><6><7><1.2><0.4><0.72>
 * 
 * <武器名>
 * <默认clipsize>：xm是7，m3是8，如果父武器是xm写7，是m3写8，反正只能写7和8这两个值
 * <实际clipsize>：武器脚本里填写的实际clipszie
 * <idle序列号>
 * <reload_end序列号>
 * <reloade_chamber序列号>
 * <reloade_chamber时间参>：根据动作帧数和fps算个完整动作时长，然后再往小调，一点点试，找到一个合适的值
 * <reloade_start时间参>
 * <reloade_loop时间参>
 */

char WeaponNames[256][32];         // 最多支持256把加枪武器，类名最多32个字符
int DefaultClipsize[256] = {0};
int ActualClipsize[256] = {0};

int IdleSequence[256] = {0};
int ReloadEndSequence[256] = {0};
int ReloadeChamberSequence[256] = {0};

float ReloadeChamberTime[256] = {0.0};
float ReloadeStartTime[256] = {0.0};
float ReloadeLoopTime[256] = {0.0};

int StartClip[MAXPLAYERS+1] = {-1};     // 记录换弹刚开始时的子弹数，-1代表未记录

Handle g_hTimerTask[MAXPLAYERS+1] = {INVALID_HANDLE};       // reloade的chamber
Handle g_hTimerTask2[MAXPLAYERS+1] = {INVALID_HANDLE};      // reloade的start loop
Handle g_hTimerTask3[MAXPLAYERS+1] = {INVALID_HANDLE};      // reloade的end
Handle g_hRepeatTask[MAXPLAYERS+1] = {INVALID_HANDLE};      // reloade的loop

Handle g_hTimerTask4[MAXPLAYERS+1] = {INVALID_HANDLE};      // 更新子弹
Handle g_hTimerTask5[MAXPLAYERS+1] = {INVALID_HANDLE};      // 收尾动作
Handle g_hRepeatTask2[MAXPLAYERS+1] = {INVALID_HANDLE};     // 用来检测是否按住左键

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

    if (g_hTimerTask[client] != INVALID_HANDLE)
    {
        KillTimer(g_hTimerTask[client]);
        g_hTimerTask[client] = INVALID_HANDLE;
    }

    if (g_hTimerTask2[client] != INVALID_HANDLE)
    {
        KillTimer(g_hTimerTask2[client]);
        g_hTimerTask2[client] = INVALID_HANDLE;
    }

    if (g_hTimerTask3[client] != INVALID_HANDLE)
    {
        KillTimer(g_hTimerTask3[client]);
        g_hTimerTask3[client] = INVALID_HANDLE;
    }

    if (g_hTimerTask4[client] != INVALID_HANDLE)
    {
        KillTimer(g_hTimerTask4[client]);
        g_hTimerTask4[client] = INVALID_HANDLE;
    }

    if (g_hTimerTask5[client] != INVALID_HANDLE)
    {
        KillTimer(g_hTimerTask5[client]);
        g_hTimerTask5[client] = INVALID_HANDLE;
    }

    if (g_hRepeatTask[client] != INVALID_HANDLE)
    {
        KillTimer(g_hRepeatTask[client]);
        g_hRepeatTask[client] = INVALID_HANDLE;
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
                if (g_hTimerTask[client] != INVALID_HANDLE
                || g_hTimerTask2[client] != INVALID_HANDLE
                || g_hTimerTask3[client] != INVALID_HANDLE
                || g_hRepeatTask[client] != INVALID_HANDLE
                || g_hRepeatTask2[client] != INVALID_HANDLE)
                    return Plugin_Continue;

                if (clip <= 0)
                    return Plugin_Continue;
                
                // 不在换弹状态，可以直接退出
                if (GetEntProp(myweapon, Prop_Send, "m_reloadState") == 0)
                {
                    // 已经达到膛内+1了，要阻止一切换弹的可能
                    if (clip >= ActualClipsize[index] + 1)
                    {
                        SetEntProp(myweapon, Prop_Send, "m_reloadState", 0);
                        buttons &= ~IN_RELOAD;
                    }

                    return Plugin_Continue;
                }

                // 确实在换弹流程，且刚开始
                if (StartClip[client] == -1)
                    StartClip[client] = clip;
        
                // 如果默认clipsize是7 xm1014
                if (DefaultClipsize[index] == XMCLIP)
                {
                    // 小于实际clipsize，且备弹有余，强制发起或者说继续换弹动作
                    if (clip < ActualClipsize[index] + 1 && ammo > 0)
                    {
                        // 下面这两行代码放一起就可以反复播放换弹动作但不会更新子弹数
                        SetEntProp(myweapon, Prop_Send, "m_reloadState", 1);
                        buttons |= IN_RELOAD;

                        // 手动更新子弹数，这个参数设置有问题，reload start和loop的耗时不同
                        if (g_hTimerTask4[client] == INVALID_HANDLE)
                        {
                            // PrintToChatAll("分支1");
                            int data = (myweapon << 16) | client;
                            float delay = (clip == StartClip[client]) ? 0.7 : 0.4;

                            g_hTimerTask4[client] = CreateTimer(delay, Timer_UpdateClip, data);
                        }
                    }

                    // 在等于实际clipsize前，备弹就为0了，不知道为什么，反正不需要收尾动作

                    // 等于实际clipsize了，需要特别处理收尾动作
                    if (clip == ActualClipsize[index] + 1)
                    {
                        // 不知道为什么最后一次loop动作有概率慢动作，姑且把这两行写上，接住上一个loop动作的感觉
                        SetEntProp(myweapon, Prop_Send, "m_reloadState", 1);
                        buttons |= IN_RELOAD;

                        // 特别播放收尾动作
                        if (g_hTimerTask5[client] == INVALID_HANDLE)
                        {
                            // PrintToChatAll("分支2");
                            int data = (myweapon << 16) | client;
                            g_hTimerTask5[client] = CreateTimer(0.4, Timer_ReloadEndAnim, data);
                        }
                    }
                }
                // 如果默认clipsize是8 m3
                else if (DefaultClipsize[index] == M3CLIP)
                {
                    if (clip < ActualClipsize[index] + 1 && ammo > 0)
                    {
                        SetEntProp(myweapon, Prop_Send, "m_reloadState", 1);
                        buttons |= IN_RELOAD;

                        if (g_hTimerTask4[client] == INVALID_HANDLE)
                        {
                            int data = (myweapon << 16) | client;
                            float delay = (clip == StartClip[client]) ? 0.7 : 0.4;        // 无法理解，为什么要和xm用一样的参数才正常

                            g_hTimerTask4[client] = CreateTimer(delay, Timer_UpdateClip, data);
                        }
                    }

                    if (clip == ActualClipsize[index] + 1)
                    {
                        SetEntProp(myweapon, Prop_Send, "m_reloadState", 1);
                        buttons |= IN_RELOAD;

                        if (g_hTimerTask5[client] == INVALID_HANDLE)
                        {
                            int data = (myweapon << 16) | client;
                            g_hTimerTask5[client] = CreateTimer(0.4, Timer_ReloadEndAnim, data);
                        }
                    }
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

public void OnClientDisconnect_Post(int client)
{
    SDKUnhook(client, SDKHook_WeaponEquipPost, OnWeaponEquip);
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
        
        // 非空仓时不触发
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
            
            if (g_hRepeatTask2[client] == INVALID_HANDLE)
                g_hRepeatTask2[client] = CreateTimer(0.1, Timer_CheckHolding, client, TIMER_REPEAT);
        }
        else
        {
            /**
             * 如果不阻止开火的话，OnWeaponReload就有可能重复执行
             * m_flNextPrimaryAttack比m_flNextAttack的强制力弱不少，长按左键时就是会反复播放start和end动作，下面这段会反复执行很多次
             * 空仓部分用这个更好，因为不影响检视
             */
            SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", GetGameTime() + 9999.0);

            SetSequence(client, ReloadeChamberSequence[index] + START, 9999);

            g_hTimerTask[client] = CreateTimer(ReloadeStartTime[index], Timer_ReloadeChamberAnim, client);
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
                    g_hTimerTask3[client] = CreateTimer(ReloadeChamberTime[index], Timer_ReloadeEndAnim, client);    // 装填一发就结束
                else
                    g_hTimerTask2[client] = CreateTimer(ReloadeChamberTime[index], Timer_StartReloadeLoopAnim, client);    // 继续loop
            }
        }
    }

    KillTimer(timer);
    g_hTimerTask[client] = INVALID_HANDLE;

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
                g_hRepeatTask[client] = CreateTimer(ReloadeLoopTime[index], Timer_ReloadeLoopAnim, client, TIMER_REPEAT);
            }
        }
    }

    KillTimer(timer);
    g_hTimerTask2[client] = INVALID_HANDLE;
    
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
                    g_hTimerTask3[client] = CreateTimer(0.0, Timer_ReloadeEndAnim, client);
                }
            }
        }
    }

    KillTimer(timer);
    g_hRepeatTask[client] = INVALID_HANDLE;

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
                SetEntProp(weapon, Prop_Send, "m_reloadState", 0);              // 防止onplayerruncmd那也运行了
            }
        }
    }

    KillTimer(timer);
    g_hTimerTask3[client] = INVALID_HANDLE;

    return Plugin_Continue;
}

//========================================================================================
// TIMER 其它
//========================================================================================

public Action Timer_CheckHolding(Handle timer, int client)
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
    g_hRepeatTask2[client] = INVALID_HANDLE;

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
    g_hTimerTask4[client] = INVALID_HANDLE;

    return Plugin_Continue;
}

public Action Timer_ReloadEndAnim(Handle timer, int data)
{
    int client = data & 0xFFFF;
    int shotgun = data >> 16;

    StartClip[client] = -1;  // 重置StartClip

    if (IsValidClient(client, true))
    {
        if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == shotgun)
        {
            int index = GetWeaponIndex(shotgun);
            
            SetSequence(client, ReloadEndSequence[index], 9999);
            SetEntProp(shotgun, Prop_Send, "m_reloadState", 0);
        }
    }

    KillTimer(timer);
    g_hTimerTask5[client] = INVALID_HANDLE;

    return Plugin_Continue;
}

//========================================================================================
// FUCTIONS
//========================================================================================

void SetSequence(int client, int sequence, int frame)
{
    int ent = GetEntPropEnt(client, Prop_Send, "m_hViewModel");

    SetEntProp(ent, Prop_Send, "m_nSequence", sequence);
    SetEntPropFloat(ent, Prop_Send, "m_flPlaybackRate", 1.0);

    // 下面这个是必要的，否则正常loop也会想插进来播放，时间写多长都ok
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
                if (StringToInt(data[1]) != XMCLIP && StringToInt(data[1]) != M3CLIP)
                    continue;

                // data 2 是整数，必须大于等于0
                if (StringToInt(data[2]) < 0)
                    continue;

                // data 3 和 4 和 5 是整数，必须大于等于0
                if (StringToInt(data[3]) < 0 || StringToInt(data[4]) < 0 || StringToInt(data[5]) < 0)
                    continue;

                // data 6 和 7 和 8 是浮点数，都必须大于0
                if (StringToFloat(data[6]) <= 0.0 || StringToFloat(data[7]) <= 0.0 || StringToFloat(data[8]) <= 0.0)
                    continue;

                // 确认合法，至少后面不会报错
                WeaponCount++;
                
                strcopy(WeaponNames[WeaponCount], strlen(data[0])+1, data[0]);
                DefaultClipsize[WeaponCount] = StringToInt(data[1]);
                ActualClipsize[WeaponCount] = StringToInt(data[2]);

                IdleSequence[WeaponCount] = StringToInt(data[3]);
                ReloadEndSequence[WeaponCount] = StringToInt(data[4]);
                ReloadeChamberSequence[WeaponCount] = StringToInt(data[5]);

                ReloadeChamberTime[WeaponCount] = StringToFloat(data[6]);
                ReloadeStartTime[WeaponCount] = StringToFloat(data[7]);
                ReloadeLoopTime[WeaponCount] = StringToFloat(data[8]);
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
