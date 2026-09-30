#include <ysclass.h>

#include "fsrvbroles.h"

// RvB: see fsrvbroles.h (YSFlight RvB Edition, 2026-09-30).

class FsRvbRoleEntry
{
public:
	YsString identifier;
	FSRVBROLE role;
};

static YsArray <FsRvbRoleEntry> &FsRvbRoleEntryList(void)
{
	static YsArray <FsRvbRoleEntry> lst;
	return lst;
}

const char *FsRvbRoleToStr(FSRVBROLE role)
{
	switch(role)
	{
	default:
	case FSRVBROLE_NONE:
		return "NONE";
	case FSRVBROLE_MULTIROLE:
		return "MULTIROLE";
	case FSRVBROLE_ATTACKER:
		return "ATTACKER";
	case FSRVBROLE_HEAVY:
		return "HEAVY";
	case FSRVBROLE_CAS:
		return "CAS";
	case FSRVBROLE_STEALTH:
		return "STEALTH";
	case FSRVBROLE_GUNNER:
		return "GUNNER";
	case FSRVBROLE_UCAV:
		return "UCAV";
	}
}

FSRVBROLE FsRvbStrToRole(const char str[])
{
	YsString s(str);
	s.Capitalize();
	if(0==strcmp(s,"MULTIROLE"))
	{
		return FSRVBROLE_MULTIROLE;
	}
	else if(0==strcmp(s,"BVR"))  // The BVR class is dropped for now (user, 2026-09-30): BVR jets fly MULTIROLE.
	{
		return FSRVBROLE_MULTIROLE;
	}
	else if(0==strcmp(s,"ATTACKER"))
	{
		return FSRVBROLE_ATTACKER;
	}
	else if(0==strcmp(s,"HEAVY"))
	{
		return FSRVBROLE_HEAVY;
	}
	else if(0==strcmp(s,"CAS"))
	{
		return FSRVBROLE_CAS;
	}
	else if(0==strcmp(s,"STEALTH"))
	{
		return FSRVBROLE_STEALTH;
	}
	else if(0==strcmp(s,"GUNNER"))
	{
		return FSRVBROLE_GUNNER;
	}
	else if(0==strcmp(s,"UCAV"))
	{
		return FSRVBROLE_UCAV;
	}
	return FSRVBROLE_NONE;  // HELI and anything unknown
}

/* static */ YSRESULT FsRvbRoleTable::AddLine(const char line[])
{
	YsString str(line);
	str.DeleteHeadSpace();
	if(0==str.Strlen() || '#'==str[0])
	{
		return YSOK;
	}

	YsArray <YsString,16> args;
	if(YSOK!=str.Arguments(args) || 2>args.GetN())
	{
		return YSERR;
	}

	YsString roleStr=args[1];
	roleStr.Capitalize();
	FSRVBROLE role=FsRvbStrToRole(roleStr);
	if(FSRVBROLE_NONE==role && 0!=strcmp(roleStr,"NONE") && 0!=strcmp(roleStr,"HELI"))
	{
		return YSERR;
	}

	auto &lst=FsRvbRoleEntryList();
	for(auto &ent : lst)
	{
		if(0==ent.identifier.STRCMP(args[0]))
		{
			ent.role=role;
			return YSOK;
		}
	}
	lst.Increment();
	lst.Last().identifier=args[0];
	lst.Last().role=role;
	return YSOK;
}

/* static */ void FsRvbRoleTable::Clear(void)
{
	FsRvbRoleEntryList().Clear();
}

/* static */ int FsRvbRoleTable::GetNumEntry(void)
{
	return (int)FsRvbRoleEntryList().GetN();
}

/* static */ FSRVBROLE FsRvbRoleTable::GetRole(const char identifier[])
{
	for(auto &ent : FsRvbRoleEntryList())
	{
		if(0==ent.identifier.STRCMP(identifier))
		{
			return ent.role;
		}
	}
	return GetRoleFromTag(identifier);
}

/* static */ FSRVBROLE FsRvbRoleTable::GetRoleFromTag(const char identifier[])
{
	YsString id(identifier);
	id.Capitalize();
	const char *idTxt=id.Txt();

	// "NAME(TEAM/ROLE)"
	const char *slash=strrchr(idTxt,'/');
	const char *close=strrchr(idTxt,')');
	if(NULL!=slash && NULL!=close && slash<close)
	{
		YsString roleStr;
		for(const char *c=slash+1; c<close; ++c)
		{
			roleStr.Append(*c);
		}
		return FsRvbStrToRole(roleStr);
	}

	// "[TEAM]ROLE", e.g. [BLUE]UCAV
	const char *bracket=strchr(idTxt,']');
	if('['==idTxt[0] && NULL!=bracket)
	{
		return FsRvbStrToRole(bracket+1);
	}
	return FSRVBROLE_NONE;
}
