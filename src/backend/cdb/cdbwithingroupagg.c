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
#include "nodes/pg_list.h"
#include "nodes/parsenodes.h"
#include "parser/parser.h"

#include "cdb/cdbwithingroupagg.h"


#define MAX_NAME_LENGTH 16


typedef struct AbsWithGrpAggContext AbsWithGrpAggContext;
typedef void (*FuncCallHandler) (AbsWithGrpAggContext *, FuncCall *);

typedef struct FuncCallInfo
{
	FuncCall    *func_call;
	List        *args_names;
	List        *order_names;
	Value       *filter_name;
} FuncCallInfo;

struct AbsWithGrpAggContext
{
	FuncCallHandler handler;
	void           *context;
	bool            quit_now;
};

typedef struct FuncCallAnalysisContext
{
	List *fc_infos;
	int   var_idx;
} FuncCallAnalysisContext;

static bool abstract_within_group_agg_walker(Node *node,
											 AbsWithGrpAggContext *abs_context);
static void quick_check_within_group_agg(AbsWithGrpAggContext *abs_context,
										 FuncCall *func_call);
static List  *build_func_call_info(List *tlist);
static void   analyze_func_call(AbsWithGrpAggContext *abs_context,
								FuncCall *func_call);
static List  *create_names(List *exprs, FuncCallAnalysisContext *context);
static Value *create_name(FuncCallAnalysisContext *context);
static CommonTableExpr *create_base_cte(List *fc_infos, SelectStmt *stmt);
static List * generate_base_cte_col_names(List *fc_infos);
static List * generate_tlist_for_base_cte(List *fc_infos);


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
		AbsWithGrpAggContext abs_context;

		abs_context.handler = quick_check_within_group_agg;
		abs_context.context= NULL;
		abs_context.quit_now = false;

		return raw_expression_tree_walker((Node *) stmt->targetList,
										  abstract_within_group_agg_walker,
										  &abs_context);
	}
	else
		return false;
}

SelectStmt *
cdb_rewrite_within_group_agg(SelectStmt *stmt)
{
	List *fc_infos = build_func_call_info(stmt->targetList);
	CommonTableExpr *base_cte = create_base_cte(fc_infos, stmt);

	/* toy test */
	char *sql = "select * from base_cte";
	RawStmt *r = linitial(raw_parser(sql));
	WithClause *withClause = makeNode(WithClause);
	withClause->ctes = list_make1(base_cte);
	SelectStmt *s = r->stmt;
	s->withClause = withClause;

	return s;
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
abstract_within_group_agg_walker(Node *node, AbsWithGrpAggContext *abs_context)
{
	if (node == NULL)
		return false;

	if (IsA(node, SubLink))
		return false;

	if (IsA(node, FuncCall))
	{
		abs_context->handler(abs_context, (FuncCall *) node);
		return abs_context->quit_now;
	}

	return raw_expression_tree_walker(node,
									  abstract_within_group_agg_walker,
									  abs_context);
}

/*
 * quick_check_within_group_agg
 *   The handler for the walk to test if do the rewrite at the very
 *   beginning. It needs to quit fast if found.
 */
static void
quick_check_within_group_agg(AbsWithGrpAggContext *abs_context, FuncCall *func_call)
{
	if (func_call->agg_within_group)
		abs_context->quit_now = true;
}

static List *
build_func_call_info(List *tlist)
{
	FuncCallAnalysisContext context = {NIL, 0};
	AbsWithGrpAggContext abs_context;
	abs_context.handler = analyze_func_call;
	abs_context.context = &context;
	abs_context.quit_now = false;

	raw_expression_tree_walker((Node *) tlist,
							   abstract_within_group_agg_walker,
							   &abs_context);

	return context.fc_infos;
}

static void
analyze_func_call(AbsWithGrpAggContext *abs_context, FuncCall *func_call)
{
	FuncCallInfo *fc_info = (FuncCallInfo *) palloc0(sizeof(FuncCallInfo));
	FuncCallAnalysisContext *context = abs_context->context;

	fc_info->func_call = func_call;
	if (func_call->args)
		fc_info->args_names = create_names(func_call->args, context);
	if (func_call->agg_order)
		fc_info->order_names = create_names(func_call->agg_order, context);
	if (func_call->agg_filter)
		fc_info->filter_name = create_name(context);

	context->fc_infos = lappend(context->fc_infos, fc_info);
}

static List *
create_names(List *exprs, FuncCallAnalysisContext *context)
{
	List *names = NIL;
	int   i;

	for (i = 0; i < list_length(exprs); i++)
	{
		names = lappend(names, create_name(context));
	}

	return names;
}

static Value *
create_name(FuncCallAnalysisContext *context)
{
	char                    *name = (char *) palloc0(MAX_NAME_LENGTH);
	snprintf(name, MAX_NAME_LENGTH, "base_col_%d", context->var_idx);
	context->var_idx++;
	return makeString(name);
}

static CommonTableExpr *
create_base_cte(List *fc_infos, SelectStmt *stmt)
{
	CommonTableExpr *cte = makeNode(CommonTableExpr);
	SelectStmt      *new_stmt = copyObject(stmt);

	cte->ctename = "base_cte";
	cte->aliascolnames = generate_base_cte_col_names(fc_infos);
	new_stmt->targetList = generate_tlist_for_base_cte(fc_infos);
	cte->ctequery = (Node *) new_stmt;

	return cte;
}

static List *
generate_base_cte_col_names(List *fc_infos)
{
	List     *col_names = NIL;
	ListCell *lc = NULL;

	foreach(lc, fc_infos)
	{
		FuncCallInfo *fc_info = (FuncCallInfo *) lfirst(lc);
		col_names = list_concat(col_names, fc_info->args_names);
		col_names = list_concat(col_names, fc_info->order_names);
		if (fc_info->filter_name)
			col_names = lappend(col_names, fc_info->filter_name);
	}

	return col_names;
}

static List *
generate_tlist_for_base_cte(List *fc_infos)
{
	List     *tlist = NIL;
	ListCell *lc = NULL;

	foreach(lc, fc_infos)
	{
		FuncCallInfo *fc_info = (FuncCallInfo *) lfirst(lc);
		FuncCall     *func_call = fc_info->func_call;
		ListCell     *lc1 = NULL;

		/* func_call arguments */
		foreach(lc1, func_call->args)
		{
			Node *node = (Node *) lfirst(lc1);
			ResTarget *rt = makeNode(ResTarget);
			rt->val = node;
			tlist = lappend(tlist, rt);
		}

		/* order by expressions */
		foreach(lc1, func_call->agg_order)
		{
			SortBy *sortby = (SortBy *) lfirst(lc1);
			ResTarget *rt = makeNode(ResTarget);
			rt->val = sortby->node;
			tlist = lappend(tlist, rt);
		}

		/* filter expression */
		if (func_call->agg_filter)
		{
			ResTarget *rt = makeNode(ResTarget);
			rt->val = func_call->agg_filter;
			tlist = lappend(tlist, rt);
		}
	}

	return tlist;
}
