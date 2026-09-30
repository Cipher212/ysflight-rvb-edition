#ifndef FSRVBROLES_IS_INCLUDED
#define FSRVBROLES_IS_INCLUDED
/* { */

// RvB: aircraft roles for the RvB tactical AI (YSFlight RvB Edition, 2026-09-30).
// The role normally comes from the aircraft identifier tag: "F-16(BLUE/MULTIROLE)", "[RED]UCAV".
// rvb_roles.txt adds or overrides entries, one "AIRCRAFT_NAME ROLE_NAME" per line (# = comment).
// The bridge reads the file and feeds its lines to FsRvbRoleTable::AddLine.

#include <ysclass.h>

enum FSRVBROLE
{
	FSRVBROLE_NONE,       // Keeps the stock YS AI (helicopters, aircraft without a known role)
	FSRVBROLE_MULTIROLE,
	FSRVBROLE_ATTACKER,
	FSRVBROLE_HEAVY,
	FSRVBROLE_CAS,
	FSRVBROLE_STEALTH,
	FSRVBROLE_GUNNER,
	FSRVBROLE_UCAV,

	FSRVBROLE_NUMROLE
};

const char *FsRvbRoleToStr(FSRVBROLE role);
FSRVBROLE FsRvbStrToRole(const char str[]);  // Also accepts the tag words in aircraft names (BVR, HELI)

class FsRvbRoleTable
{
public:
	// One line of rvb_roles.txt.  Returns YSERR for an unknown role name (the line is ignored).
	static YSRESULT AddLine(const char line[]);
	static void Clear(void);
	static int GetNumEntry(void);

	// rvb_roles.txt entry first, then the tag in the identifier, else FSRVBROLE_NONE.
	static FSRVBROLE GetRole(const char identifier[]);
	static FSRVBROLE GetRoleFromTag(const char identifier[]);
};

/* } */
#endif
