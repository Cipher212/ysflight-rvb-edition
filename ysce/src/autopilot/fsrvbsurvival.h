#ifndef FSRVBSURVIVAL_IS_INCLUDED
#define FSRVBSURVIVAL_IS_INCLUDED
/* { */

// RvB: what every RvB AI does to stay alive, whatever its role (YSFlight RvB Edition, 2026-09-30).
//  - Missile defence (every tick while a missile is on it).  YS missiles are pure pursuit with a turn-rate
//    and range budget and no Doppler radar, so the notch is kinematic: far out, put the missile on the
//    beam and dive a little so it burns range turning; close in, a max-G break across its path with
//    flares every 0.3-0.5 s (YS flares fool any missile that sees them ahead inside its seeker cone).
//    Radar missiles are always noticed (RWR); IR missiles only when spotted (fsrvbawareness.h).
//  - Odds (per scan): own-side vs known-enemy strength nearby; above the role's ratio -> bug out.
//  - Fuel (per scan): burn rate measured without afterburner (the trip home is flown at military power)
//    vs distance to the nearest friendly base -> RTB in time.
//  - Jettison: drop tanks fall off (YS FireWeapon), bombs are released safe (removed, no blast).

#include <ysclass.h>
#include <fsdef.h>
#include "fsrvbdoctrine.h"

class FsAirplane;
class FsSimulation;
class FsRvbTeamPicture;
class FsRvbAwareness;

// A steering order the tactical autopilot turns into controls (it owns the protected YS helpers).
class FsRvbSteer
{
public:
	YSBOOL active;
	double bank;          // rad, + = turn towards increasing heading
	YSBOOL useVSpeed;     // YSTRUE: hold vSpeed with G up to gLimit;  YSFALSE: pull g
	double vSpeed;        // m/s
	double g;
	double gLimit;
	double throttle;
	YSBOOL afterburner;
	YSBOOL flare;
	double gear,spoiler,flap;  // 0..1 (approach)

	FsRvbSteer();
	void Clear(void);
	// Turn towards a horizontal direction, holding a vertical speed.
	void TurnTowards(const FsAirplane &air,const YsVec3 &dir,const double gLimit,const double vSpeed);
	// Fly to a point: heading from the XZ offset, vertical speed from the altitude error.
	void FlyTo(const FsAirplane &air,const YsVec3 &pos,const double gLimit,const double maxClimb);
};

// Heading of dir minus heading of the aircraft's velocity, in (-pi,pi].  Positive = turn with + bank.
double FsRvbRelativeHeading(const FsAirplane &air,const YsVec3 &dir);
// Same, relative to where the nose points (taxiing: the velocity is too small to trust).
double FsRvbRelativeHeadingOnGround(const FsAirplane &air,const YsVec3 &dir);
// Speed over the ground from the last step.  YS's GetVelocity is airspeed: a parked jet in a 13 m/s wind
// reads 13 m/s.
double FsRvbGroundSpeed(const FsAirplane &air);

class FsRvbSurvival
{
public:
	enum DEFENCE
	{
		DEF_NONE,
		DEF_BEAM,     // Missile far: keep it 90 deg off, dive a little, full power
		DEF_BREAK     // Missile close: max-G break across its path, flares
	};

	enum RTB_REASON
	{
		RTB_NONE,
		RTB_DAMAGE,
		RTB_FUEL,
		RTB_WEAPONS,
		RTB_NUMREASON
	};
	static int nRtb[RTB_NUMREASON];  // RTBs started, by reason (all aircraft; tests and tuning)
	static const char *RtbReasonToStr(RTB_REASON r);

	DEFENCE defence;
	FSWEAPONTYPE missileType;
	double missileDist;
	double burnRate;           // kg/s, smoothed

	FsRvbSurvival();

	// Every tick.  Fills steer and returns YSTRUE while a noticed missile is on the aircraft.
	YSBOOL UpdateMissileDefence(FsRvbSteer &steer,FsAirplane &air,FsSimulation *sim,const int nMissileOnMe,
	    const FsRvbAwareness &aware,const FsRvbDoctrine &doc,const double minAlt,const double dt);

	// Per scan.
	YSBOOL OddsAgainstUs(const FsAirplane &air,const FsRvbTeamPicture &pic,const FsRvbAwareness &aware,const FsRvbDoctrine &doc) const;
	void UpdateFuel(const FsAirplane &air,const double clock);
	RTB_REASON NeedRtb(const FsAirplane &air,const FsRvbTeamPicture &pic,const FsRvbDoctrine &doc) const;

	static YSBOOL HasAirWeapon(const FsAirplane &air,const FsRvbDoctrine &doc);
	static YSBOOL HasGroundWeapon(const FsAirplane &air,const FsRvbDoctrine &doc);
	static double TotalFuel(const FsAirplane &air);
	static double DamageFraction(const FsAirplane &air);

	// Jettison.
	static void DropTanks(FsAirplane &air,FsSimulation *sim);
	static void DropBombs(FsAirplane &air);

private:
	double flareTimer;
	int breakDir;
	double lastFuel,lastFuelClock;
};

/* } */
#endif
