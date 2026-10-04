#ifndef FSEXPLOSION_IS_INCLUDED
#define FSEXPLOSION_IS_INCLUDED
/* { */

#include <ysglbuffermanager.h>

class FsExplosionRecord
{
public:
	float x,y,z;
	float remain,iniRadius,radius;
	YSBOOL flash;
	int expType;
	class FsExistence *causedBy;
};




// Declaration /////////////////////////////////////////////

enum
{
	FSEXPLOSION_FIREBALL=0,
	FSEXPLOSION_WATERPLUME=1
};

// YSFlight RvB Edition, 2026-10-03: Incident types for differentiated effects
enum FS_EXPLOSION_INCIDENT
{
	FS_INCIDENT_UNKNOWN = 0,
	FS_INCIDENT_GUN_IMPACT = 1,
	FS_INCIDENT_AIR_TO_AIR_MISSILE = 2,
	FS_INCIDENT_GROUND_ORDNANCE = 3,
	FS_INCIDENT_ENTITY_DESTRUCTION_OR_CRASH = 4,
	FS_INCIDENT_CONTINUING_WRECK_FIRE = 5
};

class FsExplosion
{
public:
	FsExplosion();

	void Move(const double &dt);
	void Draw(const YsVec3 &viewPos,YSBOOL transparency,YSBOOL useOpenGlDisplayList) const;
	void Explode(const YsVec3 &p,const double &remain,const double &iRad,const double &rad,YSBOOL flash,int incidentType=0,int weaponType=-1);
	void WaterPlume(const YsVec3 &p,const double &remain,const double &rad,const double &height,int incidentType=0,int weaponType=-1);

	int expType;
	YsVec3 pos;
	double timeRemain,timePassed;
	union
	{
		double iniRadius;
		double height;
	};
	double radius;
	YSBOOL flash;

	int incidentType; // YSFlight RvB Edition, 2026-10-03
	int weaponType;   // YSFlight RvB Edition, 2026-10-03

	int random; // A random number assigned whenever an explosion is added from simulation or from record.

	static YsGLBufferManager::Handle fireballVboHd,halfFireballVboHd;
	static YsGLBufferManager::Handle reverseFireballVboHd,reverseHalfFireballVboHd;
	static YsGLBufferManager::Handle waterPlumeVboHd;

	static const float FireBallVtx[];
	static const float Circle[];
	static void PrepareVertexArray(void);
	static void PrepareFireballVertexArray(void);
	static void PrepareWaterPlumeVertexArray(void);

	FsExplosion *next,*prev;
};



// Declaration /////////////////////////////////////////////
class FsExplosionHolder
{
public:
	FsExplosionHolder();
	~FsExplosionHolder();

	enum
	{
		NumExplosion=1024
	};

	YSRESULT Save(FILE *fp,class FsSimulation *sim);
	YSRESULT Load(FILE *fp,class FsSimulation *sim);

	void Clear(void);
	void MoveToActiveList(FsExplosion *wep);
	void MoveToFreeList(FsExplosion *wep);

	YSRESULT RipOffEarlyPartOfRecord(void);

	YSRESULT Explode(
	    const double &ctime,
	    const YsVec3 &pos,
	    const double &remain,
	    const double &iniRadius,
	    const double &radius,
	    YSBOOL flash,
	    class FsExistence *owner,
	    YSBOOL recordIt,
	    int incidentType=0,
	    int weaponType=-1);

	YSRESULT WaterPlume(
	    const double &ctime,
	    const YsVec3 &pos,
	    const double &remain,
	    const double &radius,
	    const double &height,
	    class FsExistence *owner,
	    YSBOOL recordIt,
	    int incidentType=0,
	    int weaponType=-1);

	void Move(const double &dt);
	void Draw(const YsVec3 &viewPos,YSBOOL transparency,YSBOOL useOpenGlDisplayList) const;

	void CollectRecord(void);
	void PlayRecord(const double &t1,const double &t2);

	FsExplosion buf[NumExplosion];
	FsExplosion *activeList,*freeList;

	FsRecord <FsExplosionRecord> *toPlay;
	FsRecord <FsExplosionRecord> *toSave;


// For network play
protected:
	class FsSocketServer *netServer;
	class FsSocketClient *netClient;
public:
	void SetNetServer(class FsSocketServer *svr);
	void SetNetClient(class FsSocketClient *cli);
};



/* } */
#endif
