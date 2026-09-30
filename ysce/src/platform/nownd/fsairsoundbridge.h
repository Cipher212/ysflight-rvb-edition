#ifndef FSAIRSOUNDBRIDGE_IS_INCLUDED
#define FSAIRSOUNDBRIDGE_IS_INCLUDED

// Godot audio bridge. In the headless (nownd) build the FsSound* functions play nothing; instead they
// record what the simulation asks for (for the player's aircraft), and the Godot GDExtension reads it.
// Enum values are the FSSND_* types from sounddll/fsairsoundenum.h.

struct FsSoundBridgeState
{
	enum { MAX_ONETIME_TYPES = 32 };

	int engineType;      // FSSND_ENGINETYPE
	int numEngine;
	double enginePower;  // 0..1
	int machineGun;      // FSSND_MACHINEGUNTYPE
	int alarm;           // FSSND_ALARMTYPE
	unsigned int oneTimeCount[MAX_ONETIME_TYPES]; // per FSSND_ONETIMETYPE; only ever increases
};

const FsSoundBridgeState &FsSoundGetBridgeState(void);

#endif
