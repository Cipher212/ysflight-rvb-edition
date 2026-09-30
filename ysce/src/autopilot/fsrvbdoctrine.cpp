#include <ysclass.h>

#include "fsrvbdoctrine.h"

// RvB: the role table (YSFlight RvB Edition, 2026-09-30).  Values follow the user's role spec:
//   UCAV       A2A only, CAP on the quiet flanks/rear of its own side, subpar, 7-8 G like stock YS AI.
//   MULTIROLE  A2A first, prefers AIM-120 and missiles over guns, bombs only with no enemy within
//              15 km, drops tanks and bombs when jumped, pulls close to max G, decent dogfighter.
//   ATTACKER   A2G, ignores air targets; jumped (<2.5 km or shot at): break, snapshot AIM-9, reset.
//              Low and fast.  B500 / B250 / AGM-65.  Average dogfighter.
//   HEAVY      8,000 m+ behind own lines, runways only, straight and level carpet runs, < 5 G.
//   CAS        Contour flight 100-300 m, flat pedal turns back onto the target, no high resets.
//   STEALTH    Edge orbit 15-20 km out at 6,000 m+, long AIM-120 shots from the edge of furballs,
//              boom-and-zoom or a quick gun pass then extends cold; occasional stand-off AGM-65.
//              Max G to evade, poor-to-average dogfighter.
//   GUNNER     Anchored over the map centre at 1,500-3,000 m, chases anywhere, guns only at 400 m,
//              max G, excellent dogfighter.

static void FsRvbSetCommon(FsRvbDoctrine &d,FSRVBROLE role)
{
	d.role=role;
	d.a2a=YSFALSE;
	d.a2g=YSFALSE;
	d.station=FSRVBSTATION_FRONT;
	d.stationAlt[0]=3000.0;
	d.stationAlt[1]=5000.0;
	d.gLimit=7.0;
	d.gEvade=7.5;
	d.backSenseDeg=30.0;
	d.awareSkill=1.0;
	d.radarRange=15000.0;
	d.helpWillingness=0.0;
	d.helpRange=10000.0;
	d.gunRange=700.0;
	d.aamMask=0;
	d.preferAim120=YSFALSE;
	d.engageRange=20000.0;
	d.stickiness=0.3;
	d.attackAlt=1500.0;
	d.inboundSpeed=220.0;
	d.noAirThreatRange=0.0;
	d.jumpedRange=2500.0;
	d.a2gChance=1.0;
	d.a2gWeapon[0]=FSWEAPON_NULL;
	d.a2gWeapon[1]=FSWEAPON_NULL;
	d.a2gWeapon[2]=FSWEAPON_NULL;
	d.a2gWeapon[3]=FSWEAPON_NULL;
	d.a2gGun=YSFALSE;
	d.bugOutRatio=1.5;
	d.rtbDamage=0.5;
	d.reserveFuel=0.08;
}

static void FsRvbMakeTable(FsRvbDoctrine tab[FSRVBROLE_NUMROLE])
{
	for(int i=0; i<FSRVBROLE_NUMROLE; ++i)
	{
		FsRvbSetCommon(tab[i],(FSRVBROLE)i);
	}

	FsRvbDoctrine &ucav=tab[FSRVBROLE_UCAV];
	ucav.a2a=YSTRUE;
	ucav.station=FSRVBSTATION_FLANK_CAP;
	ucav.stationAlt[0]=4000.0;
	ucav.stationAlt[1]=5500.0;
	ucav.gLimit=7.5;
	ucav.gEvade=7.5;
	ucav.backSenseDeg=20.0;
	ucav.awareSkill=0.6;
	ucav.radarRange=15000.0;
	ucav.helpWillingness=0.6;
	ucav.helpRange=12000.0;   // Its CAP area
	ucav.aamMask=FSRVBAAM_ALL;
	ucav.engageRange=12000.0;  // Around its CAP point
	ucav.stickiness=0.2;
	ucav.bugOutRatio=1.8;
	ucav.rtbDamage=0.6;

	FsRvbDoctrine &multi=tab[FSRVBROLE_MULTIROLE];
	multi.a2a=YSTRUE;
	multi.a2g=YSTRUE;
	multi.stationAlt[0]=5000.0;
	multi.stationAlt[1]=7000.0;
	multi.gLimit=8.5;
	multi.gEvade=9.0;
	multi.backSenseDeg=45.0;
	multi.awareSkill=1.2;
	multi.radarRange=30000.0;
	multi.helpWillingness=0.8;
	multi.aamMask=FSRVBAAM_ALL;
	multi.preferAim120=YSTRUE;
	multi.engageRange=25000.0;
	multi.stickiness=0.35;
	multi.attackAlt=1500.0;
	multi.inboundSpeed=230.0;
	multi.noAirThreatRange=15000.0;
	multi.jumpedRange=5000.0;
	multi.a2gWeapon[0]=FSWEAPON_BOMB;
	multi.a2gWeapon[1]=FSWEAPON_BOMB250;
	multi.a2gWeapon[2]=FSWEAPON_AGM65;
	multi.bugOutRatio=2.0;

	FsRvbDoctrine &attacker=tab[FSRVBROLE_ATTACKER];
	attacker.a2g=YSTRUE;
	attacker.stationAlt[0]=300.0;   // Low and fast transit
	attacker.stationAlt[1]=600.0;
	attacker.gLimit=8.0;
	attacker.gEvade=8.5;
	attacker.backSenseDeg=35.0;
	attacker.awareSkill=1.0;
	attacker.radarRange=10000.0;
	attacker.gunRange=600.0;
	attacker.aamMask=FSRVBAAM_SHORT;  // Snapshot AIM-9 when jumped
	attacker.engageRange=2500.0;
	attacker.attackAlt=150.0;
	attacker.inboundSpeed=260.0;
	attacker.jumpedRange=2500.0;
	attacker.a2gWeapon[0]=FSWEAPON_BOMB;
	attacker.a2gWeapon[1]=FSWEAPON_BOMB250;
	attacker.a2gWeapon[2]=FSWEAPON_AGM65;
	attacker.a2gGun=YSTRUE;
	attacker.bugOutRatio=1.3;

	FsRvbDoctrine &heavy=tab[FSRVBROLE_HEAVY];
	heavy.a2g=YSTRUE;
	heavy.station=FSRVBSTATION_OWN_REAR;
	heavy.stationAlt[0]=8000.0;
	heavy.stationAlt[1]=9000.0;
	heavy.gLimit=4.5;
	heavy.gEvade=4.8;
	heavy.backSenseDeg=0.0;
	heavy.awareSkill=0.6;
	heavy.radarRange=10000.0;
	heavy.gunRange=0.0;
	heavy.engageRange=0.0;
	heavy.attackAlt=8000.0;
	heavy.inboundSpeed=220.0;
	heavy.jumpedRange=3000.0;
	heavy.a2gWeapon[0]=FSWEAPON_BOMB;
	heavy.a2gWeapon[1]=FSWEAPON_BOMB250;
	heavy.bugOutRatio=1.0;

	FsRvbDoctrine &cas=tab[FSRVBROLE_CAS];
	cas.a2g=YSTRUE;
	cas.stationAlt[0]=150.0;  // Contour flight 100-300 m
	cas.stationAlt[1]=300.0;
	cas.gLimit=7.0;
	cas.gEvade=7.5;
	cas.backSenseDeg=30.0;
	cas.awareSkill=0.9;
	cas.radarRange=6000.0;
	cas.aamMask=FSRVBAAM_SHORT;
	cas.engageRange=2500.0;
	cas.attackAlt=150.0;
	cas.inboundSpeed=160.0;
	cas.jumpedRange=2500.0;
	cas.a2gWeapon[0]=FSWEAPON_AGM65;
	cas.a2gWeapon[1]=FSWEAPON_ROCKET;
	cas.a2gWeapon[2]=FSWEAPON_BOMB250;
	cas.a2gWeapon[3]=FSWEAPON_BOMB;
	cas.a2gGun=YSTRUE;
	cas.bugOutRatio=1.3;

	FsRvbDoctrine &stealth=tab[FSRVBROLE_STEALTH];
	stealth.a2a=YSTRUE;
	stealth.a2g=YSTRUE;
	stealth.station=FSRVBSTATION_EDGE_ORBIT;
	stealth.stationAlt[0]=6000.0;
	stealth.stationAlt[1]=8000.0;
	stealth.gLimit=8.0;
	stealth.gEvade=9.0;
	stealth.backSenseDeg=35.0;
	stealth.awareSkill=1.0;
	stealth.radarRange=35000.0;
	stealth.helpWillingness=0.5;   // Usually a long AIM-120 shot on the attacker
	stealth.helpRange=20000.0;
	stealth.gunRange=500.0;
	stealth.aamMask=FSRVBAAM_ALL;
	stealth.preferAim120=YSTRUE;
	stealth.engageRange=30000.0;
	stealth.stickiness=0.2;
	stealth.attackAlt=3000.0;  // Stand-off AGM-65
	stealth.inboundSpeed=240.0;
	stealth.noAirThreatRange=10000.0;
	stealth.jumpedRange=4000.0;
	stealth.a2gChance=0.25;    // "Occasionally"
	stealth.a2gWeapon[0]=FSWEAPON_AGM65;
	stealth.a2gWeapon[1]=FSWEAPON_BOMB;
	stealth.a2gWeapon[2]=FSWEAPON_BOMB250;
	stealth.bugOutRatio=1.5;

	FsRvbDoctrine &gunner=tab[FSRVBROLE_GUNNER];
	gunner.a2a=YSTRUE;
	gunner.station=FSRVBSTATION_CENTER;
	gunner.stationAlt[0]=1500.0;
	gunner.stationAlt[1]=3000.0;
	gunner.gLimit=9.0;
	gunner.gEvade=9.0;
	gunner.backSenseDeg=60.0;
	gunner.awareSkill=1.5;
	gunner.radarRange=12000.0;
	gunner.helpWillingness=0.9;
	gunner.gunRange=400.0;
	gunner.aamMask=0;         // Guns only
	gunner.engageRange=20000.0;
	gunner.stickiness=0.5;
	gunner.bugOutRatio=2.5;
	gunner.rtbDamage=0.6;
}

const FsRvbDoctrine &FsRvbGetDoctrine(FSRVBROLE role)
{
	static FsRvbDoctrine tab[FSRVBROLE_NUMROLE];
	static YSBOOL made=YSFALSE;
	if(YSTRUE!=made)
	{
		FsRvbMakeTable(tab);
		made=YSTRUE;
	}
	if(role<0 || FSRVBROLE_NUMROLE<=role)
	{
		role=FSRVBROLE_NONE;
	}
	return tab[role];
}
