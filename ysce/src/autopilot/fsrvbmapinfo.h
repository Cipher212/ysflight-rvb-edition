#ifndef FSRVBMAPINFO_IS_INCLUDED
#define FSRVBMAPINFO_IS_INCLUDED
/* { */

// RvB: what the RvB tactical AI knows about the map (YSFlight RvB Edition, 2026-09-30).
// Built once per field: the two teams' sides, friendly/enemy bases (airports and carriers), runways and
// (airfields and runways from the map's runway start spots, fed by the bridge; else airport/runway regions)
// the ground objects worth attacking.  Team = an IFF that has aircraft in the mission; the other IFFs
// (e.g. the RvB pirates) are neither targets nor bases, only threats.

#include <ysclass.h>
#include <fsdef.h>
#include "fssiminfo.h"

class FsSimulation;

class FsRvbMapInfo
{
public:
	class Base
	{
	public:
		FsSimInfo::BASE_TYPE type;  // AIRPORT (tag = airport area tag) or CARRIER (tag = carrier name)
		YsString tag;
		FSIFF iff;
		YSHASHKEY carrierKey;       // CARRIER only
		YsVec3 pos;                 // Updated for carriers by Refresh
	};
	class Runway
	{
	public:
		FSIFF iff;
		YsVec3 end[2];              // Centre line end points
		double width;
	};
	class GroundTarget
	{
	public:
		YSHASHKEY key;
		FSIFF iff;
		YsVec3 pos;
		YSBOOL primary;
		double threatRange;         // SAM / AAA reach, 0 = harmless
		int nDefender;              // SAM / AAA sites of its own side covering it (computed once)
	};

	class StartRunway
	{
	public:
		YsString name;
		FSIFF iff;
		YsVec3 pos,dir;
	};
	// The bridge feeds the runway start spots of the field after loading, before the first AI tick.
	static void ClearStartRunways(void);
	static void AddStartRunway(const char name[],FSIFF iff,const YsVec3 &pos,const YsVec3 &dir);

	YSBOOL valid;
	YSBOOL teamValid[FS_IFF_NEUTRAL];  // IFF has aircraft in the mission
	YsVec3 teamCenter[FS_IFF_NEUTRAL]; // Centre of each team's ground objects (or its starting aircraft)
	YsVec3 frontCenter;                // Middle between the two team centres ("map centre")
	YsVec3 axis;                       // Unit XZ vector from the first team's side to the other's
	YsVec3 lateral;                    // Unit XZ vector across the front
	double axisExtent[2];              // Game area along axis, relative to frontCenter (min < 0 < max)
	double lateralExtent[2];           // Game area across the front

	YsArray <Base> base;
	YsArray <Runway> runway;
	YsArray <GroundTarget> gnd;        // All team-owned game objects plus threats (alive checked on use)

	FsRvbMapInfo();
	void Build(FsSimulation *sim);     // Once, after the mission is loaded (first AI tick)
	void Refresh(FsSimulation *sim);   // Moving things: carrier positions

	// +1 = deep on own side, -1 = deep on the enemy side, 0 = at the front line.
	double OwnSideness(FSIFF iff,const YsVec3 &pos) const;
	// Unit XZ vector pointing towards the own side.
	YsVec3 OwnSideDir(FSIFF iff) const;
	// Position = frontCenter + along*axis(towards own side) + across*lateral, at altitude alt.
	YsVec3 MakePosition(FSIFF iff,const double along,const double across,const double alt) const;
	const Base *NearestBase(FSIFF iff,const YsVec3 &from) const;

private:
	void BuildTeams(FsSimulation *sim);
	void BuildGround(FsSimulation *sim);
	YSBOOL BuildStartRunwayAirfields(void);
	void BuildBases(FsSimulation *sim);
	void BuildRunways(FsSimulation *sim);
	void BuildExtents(void);
	void CountDefenders(void);
	static YsArray <StartRunway> &StartRunways(void);
	FSIFF GuessOwner(const YsVec3 &pos,const double radius) const;
};

/* } */
#endif
