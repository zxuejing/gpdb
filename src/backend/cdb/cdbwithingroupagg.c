/*-------------------------------------------------------------------------
 *
 * cdbwithingroupagg.c
 *	  Routines for rewriting within group agg to fit MPP database
 *
 * Portions Copyright (c) 2012-Present VMware, Inc. or its affiliates.
 *
 *
 * IDENTIFICATION
 *	    src/backend/cdb/cdbwithingroupagg.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "nodes/nodeFuncs.h"
#include "nodes/parsenodes.h"

#include "cdb/cdbwithingroupagg.h"


typedef struct AbsWithGrpAggContext AbsWithGrpAggContext;
typedef void (*FuncCallHandler) (AbsWithGrpAggContext *, FuncCall *);

struct AbsWithGrpAggContext
{
	FuncCallHandler handler;
	void           *context;
	bool            quit_now;
};

static bool abstract_within_group_agg_walker(Node *node,
											 AbsWithGrpAggContext *context);
static void quick_check_within_group_agg(AbsWithGrpAggContext *context,
										 FuncCall *fc);


/*
 * choose_mpp_within_group_agg
 *   Exported API to decide if to do the rewrite optimization.
 *   Only rewrite to an MPP query for the case withou group-clause,
 *   that kind of case will gather all data to single process and
 *   then compute aggregates which is bad in MPP database.
 */
bool
choose_mpp_within_group_agg(SelectStmt *stmt)
{
	if (stmt->groupClause == NULL &&
		stmt->scatterClause == NULL &&
		stmt->sortClause == NULL &&
		stmt->limitOffset == NULL &&
		stmt->limitCount == NULL &&
		stmt->lockingClause == NULL)
	{
		AbsWithGrpAggContext context;

		context.handler = quick_check_within_group_agg;
		context.context= NULL;
		context.quit_now = false;

		return raw_expression_tree_walker((Node *) stmt->targetList,
										  abstract_within_group_agg_walker,
										  &context);
	}
	else
		return false;
}

/*
 * abstract_within_group_agg_walker
 *   During rewriting the SQL, we need to walk the raw target list many times,
 *   at high level, each time's walk must execute in the same order to confirm
 *   naming consistency and correctness. That is why we abstract the high level
 *   walk here. To use this function, we need to provide a context with specific
 *   function to handler the FuncCall node. Set quit_now to true to make the walk
 *   quit at once.
 */
static bool
abstract_within_group_agg_walker(Node *node, AbsWithGrpAggContext *context)
{
	if (node == NULL)
		return false;

	if (IsA(node, SubLink))
		return false;

	if (IsA(node, FuncCall))
	{
		context->handler(context, (FuncCall *) node);
		return context->quit_now;
	}

	return raw_expression_tree_walker(node,
									  abstract_within_group_agg_walker,
									  context);
}

/*
 * quick_check_within_group_agg
 *   The handler for the walk to test if do the rewrite at the very
 *   beginning. It needs to quit fast if found.
 */
static void
quick_check_within_group_agg(AbsWithGrpAggContext *context, FuncCall *fc)
{
	if (fc->agg_within_group)
		context->quit_now = true;
}
