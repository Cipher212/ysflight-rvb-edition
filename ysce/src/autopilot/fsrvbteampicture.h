#ifndef FSRVBTEAMPICTURE_IS_INCLUDED
#define FSRVBTEAMPICTURE_IS_INCLUDED
/* { */

// RvB: the shared picture every RvB AI reads instead of scanning the whole sim itself
// (YSFlight RvB Edition, 2026-09-30).  One pass over the aircraft and missiles every REFRESH seconds of
// sim time, whoever asks first; each AI then works on this small array on its own 1.5-2.5 s scan timer.
// With 64 aircraft that is one O(N) pass per refresh instead of N scans of N aircraft every tick.

#include <ysclass.h>
#include <fsdef.h>
#include "fsrvbroles.h"
#include "fsrvbmapinfo.h"

class FsSimulation;
class FsAirplane;

class FsRvbTeamPicture
{
public:
	enum
	{
		MAX_TEAM=FS_IFF_NEUTRAL
	};

	class AirContact
	{
	public:
		YSHASHKEY key;
		FSIFF iff;
		FSRVBROLE role;
		YsVec3 pos,vel,fwd;
		YSBOOL airborne;
		YSBOOL isPlayer;
		YSHASHKEY engagedKey;   // Air target it is working on (RvB AI) or locked (others)
		int nMissileOnIt;       // Guided missiles chasing it right now
		YSHASHKEY attackerKey;  // An enemy engaging it from within FSRVB_ATTACKER_RANGE, else YSNULLHASHKEY
		double damage;          // 0 = intact, 1 = destroyed
	};

	FsRvbMapInfo map;
	YsArray <AirContact> air;
	double lastRefresh;
	int nRefresh;               // For the tests: proves the refresh is throttled

	static FsRvbTeamPicture &Get(FsSimulation *sim);  // Refreshes when stale
	static void Reset(void);                            // New mission

	const AirContact *FindAir(YSHASHKEY key) const;
	// RvB AIs of this team already engaging the target.
	int CountEngaging(FSIFF iff,YSHASHKEY targetKey,YSHASHKEY exceptKey) const;
	// Nearest airborne enemy (any role) and its distance; NULL if none within maxDist.
	const AirContact *NearestEnemy(double &dist,FSIFF iff,const YsVec3 &pos,const double maxDist) const;

private:
	FsSimulation *simCache;
	FsRvbTeamPicture();
	void Refresh(FsSimulation *sim);
};

/* } */
#endif
