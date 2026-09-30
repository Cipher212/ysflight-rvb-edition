#ifndef FSRVBROLETASKS_IS_INCLUDED
#define FSRVBROLETASKS_IS_INCLUDED
/* { */

// RvB: role-specific choices of the RvB tactical AI (YSFlight RvB Edition, 2026-09-30):
// which air or ground target to take, which runway a HEAVY bombs, and where each role waits.
// All choices work on the team picture and the AI's own awareness (it only picks enemies it knows of).

#include <ysclass.h>
#include <fsdef.h>
#include "fsrvbdoctrine.h"

class FsAirplane;
class FsSimulation;
class FsRvbTeamPicture;
class FsRvbAwareness;

class FsRvbRoleTasks
{
public:
	// Best known enemy aircraft to go after, YSNULLHASHKEY if none.  Team mates' calls it has heard make
	// their attackers attractive (depending on the role's help willingness).
	static YSHASHKEY ChooseAirTarget(const FsAirplane &air,const FsRvbTeamPicture &pic,const FsRvbAwareness &aware,
	    const FsRvbDoctrine &doc,YSHASHKEY current,const YsVec3 &stationPos);

	// Best enemy ground object for the role, YSNULLHASHKEY if none.
	static YSHASHKEY ChooseGroundTarget(const FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic,
	    const FsRvbDoctrine &doc,YSHASHKEY current);

	// HEAVY: index into pic.map.runway of the enemy runway to carpet, -1 if none.  runStart gets the end
	// nearer to the own side (the run goes from there down the runway).
	static int ChooseRunway(YsVec3 &runStart,YsVec3 &runEnd,const FsAirplane &air,const FsRvbTeamPicture &pic,int runCount);

	// Where the role waits when it has nothing better to do.  slot spreads aircraft of the same role.
	static YsVec3 StationPosition(const FsAirplane &air,const FsRvbTeamPicture &pic,const FsRvbDoctrine &doc,int slot);

	// Nearest known enemy aircraft distance (YsInfinity if none).
	static double NearestKnownEnemy(const FsAirplane &air,const FsRvbTeamPicture &pic,const FsRvbAwareness &aware);
};

/* } */
#endif
