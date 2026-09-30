#ifndef FSRVBAWARENESS_IS_INCLUDED
#define FSRVBAWARENESS_IS_INCLUDED
/* { */

// RvB: what an RvB AI knows about the enemies around it (YSFlight RvB Edition, 2026-09-30).
// Updated on the AI's scan timer.  Detection depends on where the enemy is relative to the nose
// (numbers for an average pilot, awareSkill = 1; ranges and chances scale with the role's skill):
//   FRONT  (within 60 deg of the nose)  radar: known at once out to the role's radarRange.
//   SIDE   (60-120 deg)                 eyes:  known at once inside 1.5 km; 1.5-5 km: noticed at up to
//                                              0.6 per second, falling to 0 at 5 km.
//   REAR   (more than 120 deg)          check-six: known at once inside 300 m; 300 m-2 km: noticed at up to
//                                              0.12 per second, falling to 0 at 2 km.
// So a human closing from behind at 100 m/s is still unseen at 600 m about half the time, but never
// gets inside 300 m unseen: there is always a moment to start the break.
// Taking hits reveals the nearest enemy within 1.5 km.  A known enemy stays known while it stays
// within 1.25x the range of the zone it is in, and for 6 s after that.
// Team mates in trouble (missile on them, or an enemy on them) within the role's helpRange are heard
// at 0.5 per second, with the attacker's position off by up to 10% of the distance.

#include <ysclass.h>
#include <fsdef.h>
#include "fsrvbdoctrine.h"

class FsAirplane;
class FsRvbTeamPicture;

class FsRvbAwareness
{
public:
	enum ASPECT
	{
		ASPECT_FRONT,
		ASPECT_SIDE,
		ASPECT_REAR
	};

	class Known
	{
	public:
		YSHASHKEY key;
		double lastSeen;       // Sim clock
	};
	class Call
	{
	public:
		YSHASHKEY friendKey;   // Team mate in trouble
		YSHASHKEY attackerKey; // Its attacker (YSNULLHASHKEY: only a missile on it)
		YsVec3 roughPos;       // Where the attacker roughly is
		double heardAt;
		YSBOOL willHelp;       // Rolled once against the role's helpWillingness when heard
	};

	YsArray <Known,16> known;
	YsArray <Call,4> calls;

	void Clear(void);
	void Scan(const FsAirplane &air,const FsRvbTeamPicture &pic,const FsRvbDoctrine &doc,
	          const double clock,const double scanDt,const YSBOOL gotHit);

	YSBOOL IsKnown(YSHASHKEY key) const;
	const Call *FindCallAbout(YSHASHKEY attackerKey) const;
	// An IR missile is seen only when close: 3 km ahead, 2 km on the side, 1 km behind (x awareSkill).
	YSBOOL SpotsIrMissile(const FsAirplane &air,const YsVec3 &missilePos,const FsRvbDoctrine &doc) const;
	static ASPECT GetAspect(const FsAirplane &air,const YsVec3 &pos);
	// Known enemy closest behind (rear or side, nose on us), within range.  NULL if none.
	YSHASHKEY KnownThreatBehind(const FsAirplane &air,const FsRvbTeamPicture &pic,const double range) const;

private:
	void Forget(const double clock);
	void Remember(YSHASHKEY key,const double clock);
};

/* } */
#endif
