#ifndef FSRVBTACTICALAUTOPILOT_IS_INCLUDED
#define FSRVBTACTICALAUTOPILOT_IS_INCLUDED
/* { */

// RvB: the RvB tactical AI (YSFlight RvB Edition, 2026-09-30).
// One brain for every RvB combat role.  It is not a dogfight AI with extras: it inherits FsAutopilot and
// drives the stock YS behaviours as sub-states - FsDogfight for air combat, FsGroundAttack for ground
// attack - plus its own modules:
//   fsrvbroles / fsrvbdoctrine   role of the aircraft and every tuning number per role
//   fsrvbteampicture / mapinfo   shared picture of the battle, refreshed 4x a second for all AIs
//   fsrvbawareness               what this AI knows (radar ahead, eyes on the sides, weak rear, radio)
//   fsrvbsurvival                missile defence, odds, fuel, jettison
//   fsrvbroletasks               target and station choice per role
//   fsrvbrunwayrun               HEAVY carpet runs
//   fsrvbrecovery                RTB, military landing, fast taxi, 5 s refuel, take-off
// Decisions are made on a 1.5-2.5 s scan timer per aircraft (staggered); only missile defence and the
// active sub-state run every tick.
// fsworld.cpp swaps a mission's DOGFIGHT / GNDATACK intention for this class when the aircraft has an RvB
// role (WrapIntention); helicopters and unknown aircraft keep the stock AI.

#include "fsautopilot.h"
#include "fsrvbroles.h"
#include "fsrvbdoctrine.h"
#include "fsrvbawareness.h"
#include "fsrvbsurvival.h"
#include "fsrvbrecovery.h"
#include "fsrvbrunwayrun.h"

class FsRvbTeamPicture;

class FsRvbTacticalAutopilot : public FsAutopilot
{
public:
	enum TASK
	{
		TASK_LAUNCH,     // On the ground: taxi and take off (recovery)
		TASK_STATION,    // Nothing to do: fly to / orbit the role's station
		TASK_A2A,        // FsDogfight on the chosen air target
		TASK_A2G,        // FsGroundAttack on the chosen ground target
		TASK_RUNWAY,     // HEAVY carpet run
		TASK_EXTEND,     // Run away cold at full power (STEALTH after a slash)
		TASK_DEFEND,     // Jumped, role without dogfighting: break, snapshot AIM-9, then back to work
		TASK_BUGOUT,     // Odds against it: tanks off, low, fast, home
		TASK_RTB         // Home to land, refuel and take off again (recovery)
	};

	static YSBOOL enabled;  // The bridge clears it for --stock-ai
	// Ground operations (RTB, landing, taxi, refuel, ground starts) are archived for now (user, 2026-09-30):
	// off = no RTB, the AI fights until it dies and respawns in the air.  --ai-ground-ops turns them on.
	// Status and open issues: logs/phase9_rvb_ai_log.md.
	static YSBOOL groundOps;

	virtual FSAUTOPILOTTYPE Type(void) const override {return FSAUTOPILOT_RVBTACTICAL;}

	static FsRvbTacticalAutopilot *Create(FSRVBROLE role);
	// Replaces a mission DOGFIGHT / GNDATACK intention when the aircraft has an RvB role; else returns ap.
	static FsAutopilot *WrapIntention(FsAirplane &air,FsAutopilot *ap);
	static const char *TaskToStr(TASK task);

	FSRVBROLE GetRole(void) const;
	TASK GetTask(void) const;
	YSHASHKEY GetEngagedAirKey(void) const;
	const FsRvbRecovery &GetRecovery(void) const;
	const FsRvbAwareness &GetAwareness(void) const;

	virtual YSBOOL IsTakingOff(void) const override;
	virtual YSBOOL IsLanding(void) override;
	virtual YSRESULT MakePriorityDecision(FsAirplane &air) override;
	virtual YSRESULT MakeDecision(FsAirplane &air,FsSimulation *sim,const double &dt) override;
	virtual YSRESULT ApplyControl(FsAirplane &air,FsSimulation *sim,const double &dt) override;
	virtual YSRESULT SaveIntention(FILE *fp,const FsSimulation *sim) override;

protected:
	FsRvbTacticalAutopilot();
	virtual ~FsRvbTacticalAutopilot();

private:
	FSRVBROLE role;
	const FsRvbDoctrine *doc;
	TASK task;
	YSBOOL initialized;
	YSBOOL steering;         // This tick's controls come from steer
	double clock,scanTimer,lastScanClock,taskTimer,snapshotTimer;
	double terrainTimer,terrainTop;
	int lastDamage;
	int slot;
	int runCount;
	int aim120Left;
	YSHASHKEY airTargetKey,gndTargetKey,threatKey;
	YsVec3 stationPos,extendDir;

	class FsDogfight *a2a;
	class FsGroundAttack *a2g;
	FsRvbSurvival survival;
	FsRvbAwareness aware;
	FsRvbRecovery recovery;
	FsRvbRunwayRun runwayRun;
	FsRvbSteer steer;

	// fsrvbtacticalautopilot.cpp
	void Initialize(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic);
	void SetTask(TASK t);
	void ApplySteer(FsAirplane &air,FsSimulation *sim,const FsRvbSteer &s,const double dt);
	void TerrainGuard(FsAirplane &air,FsSimulation *sim,const double dt);
	double TaskMinAlt(void) const;
	static void CaptureReloadCommand(FsAirplane &air);

	// fsrvbtacticaldecide.cpp
	void Scan(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic);
	void ChooseTask(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic);
	YSBOOL StealthShouldExtend(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic);
	void StartAirTask(FsAirplane &air,FsSimulation *sim,YSHASHKEY target);
	void StartGroundTask(FsAirplane &air,FsSimulation *sim,YSHASHKEY target);
	void StartExtend(FsAirplane &air,const FsRvbTeamPicture &pic,YSHASHKEY from);
	void StartRtb(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic);
	void DecideSteer(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic,const double dt);
	void SnapshotShot(FsAirplane &air,FsSimulation *sim);
};

/* } */
#endif
