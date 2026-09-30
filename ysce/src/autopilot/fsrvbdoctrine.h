#ifndef FSRVBDOCTRINE_IS_INCLUDED
#define FSRVBDOCTRINE_IS_INCLUDED
/* { */

// RvB: per-role numbers for the RvB tactical AI (YSFlight RvB Edition, 2026-09-30).
// Every tuning value of the AI lives in the table in fsrvbdoctrine.cpp; the behaviour code reads it.

#include <fsdef.h>
#include "fsrvbroles.h"

enum FSRVBSTATION
{
	FSRVBSTATION_FRONT,       // Go where the targets are
	FSRVBSTATION_CENTER,      // Anchor over the map centre, chase from there (GUNNER)
	FSRVBSTATION_FLANK_CAP,   // Patrol the quiet flanks and rear of the own side (UCAV)
	FSRVBSTATION_EDGE_ORBIT,  // Orbit out at the map edge, 15-20 km off the fight (STEALTH)
	FSRVBSTATION_OWN_REAR     // Climb behind the own lines before a run (HEAVY)
};

enum
{
	FSRVBAAM_AIM9=1,
	FSRVBAAM_AIM9X=2,
	FSRVBAAM_AIM120=4,
	FSRVBAAM_SHORT=FSRVBAAM_AIM9|FSRVBAAM_AIM9X,
	FSRVBAAM_ALL=FSRVBAAM_AIM9|FSRVBAAM_AIM9X|FSRVBAAM_AIM120
};

class FsRvbDoctrine
{
public:
	FSRVBROLE role;
	YSBOOL a2a;                 // Takes air targets as a task (others only defend themselves)
	YSBOOL a2g;                 // Takes ground targets as a task
	FSRVBSTATION station;
	double stationAlt[2];       // m, min/max altitude of the station / transit

	// Air combat
	double gLimit;              // Normal manoeuvring G
	double gEvade;              // Missile defence / defensive break G
	double backSenseDeg;        // FsDogfight rear cone for its current target (stock missions use 15 deg)
	double awareSkill;          // Scales the look-out ranges and chances in fsrvbawareness.cpp (1 = average)
	double radarRange;          // m: enemies inside the front 60 deg cone are known out to this range
	double helpWillingness;     // Chance to go and help a team mate in trouble once it has heard the call
	double helpRange;           // m: calls from team mates farther than this are ignored
	double gunRange;            // m (stock FsDogfight: 700)
	unsigned int aamMask;       // FSRVBAAM_*
	YSBOOL preferAim120;
	double engageRange;         // m: air targets farther than this are left alone
	double stickiness;          // Score bonus for keeping the current target (0-1)

	// Ground attack
	double attackAlt;           // m above sea level for the run
	double inboundSpeed;        // m/s
	double noAirThreatRange;    // m: A2G only when no enemy aircraft is this close (0: ignore)
	double jumpedRange;         // m: an enemy fighter this close counts as "jumped"
	double a2gChance;           // Per scan: chance to pick a ground task when both are possible
	FSWEAPONTYPE a2gWeapon[4];  // Preferred ground weapons, first loaded one wins (FSWEAPON_NULL ends)
	YSBOOL a2gGun;              // Strafe when no preferred weapon is left

	// Survival
	double bugOutRatio;         // Bug out when enemy strength / own-side strength goes above this
	double rtbDamage;           // RTB when this fraction of the airframe is lost
	double reserveFuel;         // Fraction of max internal fuel kept in hand when planning the RTB
};

const FsRvbDoctrine &FsRvbGetDoctrine(FSRVBROLE role);

/* } */
#endif
