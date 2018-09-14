#include "postgres.h"
#include "funcapi.h"
#include "tablefuncapi.h"
#include "miscadmin.h"

#include "access/appendonlywriter.h"
#include "access/heapam.h"
#include "storage/bufmgr.h"

PG_MODULE_MAGIC;

extern void flush_relation_buffers(PG_FUNCTION_ARGS);
extern void remove_ao_entry_from_hash_table(PG_FUNCTION_ARGS);

PG_FUNCTION_INFO_V1(flush_relation_buffers);

void
flush_relation_buffers(PG_FUNCTION_ARGS)
{
	Oid relid = PG_GETARG_OID(0);
	Relation r = heap_open(relid, AccessShareLock);
	FlushRelationBuffers(r);
	heap_close(r, AccessShareLock);
}

PG_FUNCTION_INFO_V1(remove_ao_entry_from_hash_table);
void
remove_ao_entry_from_hash_table(PG_FUNCTION_ARGS)
{
	Oid relid = PG_GETARG_OID(0);

	LWLockAcquire(AOSegFileLock, LW_EXCLUSIVE);
	AORelHashEntry aoentry = AORelGetHashEntry(relid);
	if (aoentry->txns_using_rel != 0)
		elog(ERROR, "relid %d is used by %d transactions, cannot remove it yet",
			 relid, aoentry->txns_using_rel);
	AORelRemoveHashEntry(relid);
	LWLockRelease(AOSegFileLock);
}

