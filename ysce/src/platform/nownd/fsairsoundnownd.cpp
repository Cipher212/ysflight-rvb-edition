#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>


#include <ysclass.h>
#include <fs.h>

#include "../../voicedll/fsvoiceenum.h"
#include "fsairsoundbridge.h"

// See fsairsoundbridge.h: record the requested sound state instead of playing it.
static FsSoundBridgeState fsSoundBridge={FSSND_ENGINE_SILENT,0,0.0,FSSND_MACHINEGUN_SILENT,FSSND_ALARM_SILENT,{0}};
static_assert(FSSND_NUM_ONETIMETYPE<=FsSoundBridgeState::MAX_ONETIME_TYPES,"FsSoundBridgeState::oneTimeCount too small");

const FsSoundBridgeState &FsSoundGetBridgeState(void)
{
	return fsSoundBridge;
}

////////////////////////////////////////////////////////////


void FsSoundInitialize(void)
{
}


void FsSoundTerminate(void)
{
}


void FsSoundSetMasterSwitch(YSBOOL sw)
{
}

void FsSoundSetEnvironmentalSwitch(YSBOOL sw)
{
}

void FsSoundSetOneTimeSwitch(YSBOOL sw)
{
}


void FsSoundStopAll(void)
{
	fsSoundBridge.engineType=FSSND_ENGINE_SILENT;
	fsSoundBridge.enginePower=0.0;
	fsSoundBridge.machineGun=FSSND_MACHINEGUN_SILENT;
	fsSoundBridge.alarm=FSSND_ALARM_SILENT;
}

void FsSoundSetVehicleName(const char [])
{
}

void FsSoundSetEngine(FSSND_ENGINETYPE engineType,int numEngine,const double power)
{
	fsSoundBridge.engineType=engineType;
	fsSoundBridge.numEngine=numEngine;
	fsSoundBridge.enginePower=power;
}

void FsSoundSetMachineGun(FSSND_MACHINEGUNTYPE machineGunType)
{
	fsSoundBridge.machineGun=machineGunType;
}

void FsSoundSetAlarm(FSSND_ALARMTYPE alarmType)
{
	fsSoundBridge.alarm=alarmType;
}

void FsSoundSetOneTime(FSSND_ONETIMETYPE oneTimeType)
{
	if(0<=oneTimeType && oneTimeType<FsSoundBridgeState::MAX_ONETIME_TYPES)
	{
		++fsSoundBridge.oneTimeCount[oneTimeType];
	}
}

void FsSoundKeepPlaying(void)
{
}


////////////////////////////////////////////////////////////


void FsVoiceStopAll(void)
{
}

void FsVoiceSpeak(int nVoicePhrase,const struct FsVoicePhrase voicePhrase[])
{
}

void FsVoiceKeepSpeaking(void)
{
}
