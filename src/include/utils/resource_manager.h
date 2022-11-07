/*-------------------------------------------------------------------------
 *
 * resource_manager.h
 *	  GPDB resource manager definitions.
 *
 *
 * Portions Copyright (c) 2006-2017, Greenplum inc.
 * Portions Copyright (c) 2012-Present VMware, Inc. or its affiliates.
 *
 * IDENTIFICATION
 *		src/include/utils/resource_manager.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef RESOURCEMANAGER_H
#define RESOURCEMANAGER_H

#include "utils/resgroup.h"
#include "storage/lock.h"

/*
 * Caution: resource group may be enabled but not activated.
 */
#define IsResGroupEnabled() \
	(ResourceScheduler && \
	 Gp_resource_manager_policy == RESOURCE_MANAGER_POLICY_GROUP)

/*
 * Resource group do not govern the auxiliary processes and special backends
 * like ftsprobe, filerep process, so we need to check if resource group is
 * actually activated
 */
#define IsResGroupActivated() \
	(ResGroupActivated)

typedef enum
{
	/*
	 * If gp_resource_manager is group, we must config cgroup.
	 * though resource_scheduler is false.
	 * Add RESOURCE_MANAGER_POLICY_NONE to indicate do not use
	 * any resource manager.
	 */
	RESOURCE_MANAGER_POLICY_NONE,
	RESOURCE_MANAGER_POLICY_GROUP,
} ResourceManagerPolicy;

/*
 * GUC variables.
 */
extern bool	ResourceScheduler;
extern ResourceManagerPolicy Gp_resource_manager_policy;
extern bool ResGroupActivated;

extern void ResManagerShmemInit(void);
extern void InitResManager(void);

#endif   /* RESOURCEMANAGER_H */
