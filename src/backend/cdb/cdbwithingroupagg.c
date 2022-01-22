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
#include "nodes/makefuncs.h"
#include "nodes/pg_list.h"
#include "nodes/parsenodes.h"
#include "parser/parser.h"

#include "cdb/cdbwithingroupagg.h"


#define MAX_NAME_LENGTH 32
#define WITHIN_GROUP_AGG_SQL_PATTERN \
	"select 1 from " \
	"(select %s as a, %s as rnum " \
	"from %s, %s order by 1)tmp"

static char *base_cte_name = "base_cte";
static char *row_number_cte_name = "row_number_cte";
static char *col_ref_name_prefix = "col_ref";
static char *row_count_name_prefix = "row_count";
static char *cte_func_call_prefix = "cte_func_call";


typedef struct AbsWithGrpAggContext AbsWithGrpAggContext;
typedef void (*FuncCallHandler) (AbsWithGrpAggContext *, FuncCall *);

typedef struct FuncCallInfo
{
	FuncCall    *func_call;
	List        *args_names; /* TODO: count(*) ???? */
	Value       *order_name;
	Value       *filter_name;
	Value       *row_cnt_name;
	Value       *cte_name;
	int          name_index;
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
static List  *create_var_names(int len_names, FuncCallAnalysisContext *context);
static Value *create_name(char *prefix, char *content);
static Value *create_cte_name_for_func_call(FuncCallInfo *fc_info);
static Value *create_row_cnt_name(Value *expr_name);
static ColumnRef *make_column_ref(Value *name);
static CommonTableExpr *create_base_cte(List *fc_infos, SelectStmt *stmt);
static List * generate_base_cte_col_names(List *fc_infos);
static List * generate_tlist_for_base_cte(List *fc_infos);
static CommonTableExpr *create_row_number_cte(List *fc_infos);
static ResTarget *make_count_row_func_call(Value *exp_name, Value *filter_name);
static CommonTableExpr *create_within_group_cte(FuncCallInfo *fc_info);
static List *create_within_group_ctes(List *fc_infos);


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
	// TODO: add a GUC to control
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
	List            *fc_infos = NIL;
	List            *all_ctes = NIL;
	CommonTableExpr *base_cte;
	CommonTableExpr *tot_row_number_cte;
	List            *within_group_ctes;

	fc_infos = build_func_call_info(stmt->targetList);

	/* build the base CTE to wrap the main plan */
	base_cte = create_base_cte(fc_infos, stmt);
	all_ctes = lappend(all_ctes, base_cte);

	/* build total row numnber CTE */
	tot_row_number_cte = create_row_number_cte(fc_infos);
	all_ctes = lappend(all_ctes, tot_row_number_cte);

	/* build the within group ctes */
	within_group_ctes = create_within_group_ctes(fc_infos);
	all_ctes = list_concat(all_ctes, within_group_ctes);

	/* toy test */
	//char *sql = "select * from base_cte, row_number_cte";
	char sql[256] = {0};
	snprintf(sql, 256, "select * from %s",
			 ((CommonTableExpr*) linitial(within_group_ctes))->ctename);
	RawStmt *r = linitial(raw_parser(sql));
	WithClause *withClause = makeNode(WithClause);
	withClause->ctes = all_ctes;
	SelectStmt *s = (SelectStmt *) r->stmt;
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

/*
 * analyze_func_call
 *   This function does two things:
 *     - store the subpart of a FuncCall for later rewrtiting,
 *     - set names for subparts and CTEs to build
 *
 *   For within group agg, it's the core the rewrite logic, and
 *   the value will be wrapped into a CTE: CTE_name(CTE_col_name),
 *   the name is created here and CTE_name is the same as CTE_col_name,
 *   and stored in the single field cte_name.
 *
 *   For normal func call, the filed cte_name is the column ref variable
 *   to the whole expr.
 */
static void
analyze_func_call(AbsWithGrpAggContext *abs_context, FuncCall *func_call)
{
	FuncCallInfo *fc_info = (FuncCallInfo *) palloc0(sizeof(FuncCallInfo));
	FuncCallAnalysisContext *context = abs_context->context;

	fc_info->func_call = func_call;
	fc_info->name_index = context->var_idx;
	context->var_idx++;

	/* within group agg's func expect const no need to create var */
	if (!func_call->agg_within_group && func_call->args)
	{
		fc_info->args_names = create_var_names(list_length(func_call->args),
											   context);
	}

	if (func_call->agg_order)
		fc_info->order_name = (Value *) linitial(create_var_names(1, context));

	if (func_call->agg_filter)
		fc_info->filter_name = (Value *) linitial(create_var_names(1, context));

	fc_info->cte_name = create_cte_name_for_func_call(fc_info);

	if (func_call->agg_within_group)
		fc_info->row_cnt_name = create_row_cnt_name(fc_info->order_name);

	context->fc_infos = lappend(context->fc_infos, fc_info);
}

static List *
create_var_names(int len_names, FuncCallAnalysisContext *context)
{
	int    i;
	List  *names = NIL;

	for (i = 0; i < len_names; i++)
	{
		char   num[MAX_NAME_LENGTH] = {0};
		Value *name;
		snprintf(num, MAX_NAME_LENGTH, "%d", context->var_idx);
		name = create_name(col_ref_name_prefix, num);
		names = lappend(names, name);
		context->var_idx++;
	}

	return names;
}

static Value *
create_name(char *prefix, char *content)
{
	char       *name = (char *) palloc0(MAX_NAME_LENGTH);
	snprintf(name, MAX_NAME_LENGTH, "%s_%s", prefix, content);
	return makeString(name);
}

static Value *
create_cte_name_for_func_call(FuncCallInfo *fc_info)
{
	FuncCall *func_call = fc_info->func_call;

	if (func_call->agg_within_group)
	{
		Value *order_name = fc_info->order_name;
		return create_name(cte_func_call_prefix, strVal(order_name));
	}
	else
	{
		char name[MAX_NAME_LENGTH] = {0};
		snprintf(name, MAX_NAME_LENGTH, "%d", fc_info->name_index);
		return create_name(cte_func_call_prefix, name);
	}
}

static Value *
create_row_cnt_name(Value *expr_name)
{
	return create_name(row_count_name_prefix, strVal(expr_name));
}

static CommonTableExpr *
create_base_cte(List *fc_infos, SelectStmt *stmt)
{
	CommonTableExpr *cte = makeNode(CommonTableExpr);
	SelectStmt      *new_stmt = copyObject(stmt);

	cte->ctename = base_cte_name;
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
		if (fc_info->order_name)
			col_names = lappend(col_names, fc_info->order_name);
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

		/* func_call arguments, withingroup agg expect const */
		if (!func_call->agg_within_group)
		{
			foreach(lc1, func_call->args)
			{
				Node *node = (Node *) lfirst(lc1);
				ResTarget *rt = makeNode(ResTarget);
				rt->val = node;
				tlist = lappend(tlist, rt);
			}
		}

		/* order by expressions */
		if (func_call->agg_order)
		{
			/* XXX: only first */
			SortBy *sortby = (SortBy *) linitial(func_call->agg_order);
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

static CommonTableExpr *
create_row_number_cte(List *fc_infos)
{
	CommonTableExpr *cte = makeNode(CommonTableExpr);
	SelectStmt      *ctequery = makeNode(SelectStmt);
	List            *from = NIL;
	ListCell        *lc = NULL;
	List            *tlist = NIL;
	List            *col_names = NIL;

	cte->ctename = row_number_cte_name;

	foreach(lc, fc_infos)
	{
		FuncCallInfo *fc_info = (FuncCallInfo *) lfirst(lc);
		FuncCall     *func_call = fc_info->func_call;
		if (func_call->agg_within_group)
		{
			ResTarget *count_row;
			count_row = make_count_row_func_call(fc_info->order_name,
												 fc_info->filter_name);
			tlist = lappend(tlist, count_row);
			col_names = lappend(col_names, fc_info->row_cnt_name);
		}
	}

	cte->aliascolnames = col_names;
	from = list_make1(makeRangeVar(NULL, "base_cte", -1));
	ctequery->fromClause = from;
	ctequery->targetList = tlist;
	cte->ctequery = (Node *) ctequery;

	return cte;
}

static ResTarget *
make_count_row_func_call(Value *exp_name, Value *filter_name)
{
	ResTarget *rt = makeNode(ResTarget);
	FuncCall  *func_call = makeNode(FuncCall);

	func_call->funcname = list_make1(makeString("count"));
	func_call->args = list_make1(make_column_ref(exp_name));

	if (filter_name)
		func_call->agg_filter = (Node *) make_column_ref(filter_name);

	rt->val = (Node *) func_call;

	return rt;
}

static List *
create_within_group_ctes(List *fc_infos)
{
	ListCell *lc = NULL;
	List     *ctes = NIL;

	foreach(lc, fc_infos)
	{
		FuncCallInfo *fc_info = (FuncCallInfo *) lfirst(lc);
		ctes = lappend(ctes, create_within_group_cte(fc_info));
	}

	return ctes;
}

static CommonTableExpr *
create_within_group_cte(FuncCallInfo *fc_info)
{
	FuncCall        *func_call = fc_info->func_call;
	CommonTableExpr *cte = makeNode(CommonTableExpr);
	ResTarget       *rt = makeNode(ResTarget);
	char            *sql_template = WITHIN_GROUP_AGG_SQL_PATTERN;
	char             sql[256] = {0};
	FuncCall        *special_agg = makeNode(FuncCall);
	SelectStmt      *stmt;

	cte->ctename = strVal(fc_info->cte_name);
	cte->aliascolnames = list_make1(fc_info->cte_name);
	snprintf(sql, 256, sql_template,
			 strVal(fc_info->order_name),
			 strVal(fc_info->row_cnt_name),
			 base_cte_name, row_number_cte_name);
	stmt = (SelectStmt *) (((RawStmt *) linitial(raw_parser(sql)))->stmt);
	special_agg->funcname = list_make1(makeString("special_agg"));
	special_agg->args = list_make3(linitial(func_call->args),
								   make_column_ref(makeString("a")),
								   make_column_ref(makeString("rnum")));

	if (fc_info->filter_name)
		special_agg->agg_filter = (Node *) make_column_ref(fc_info->filter_name);

	rt->val = (Node *) special_agg;
	stmt->targetList = list_make1(rt);
	cte->ctequery = (Node *) stmt;

	return cte;
}

static ColumnRef *
make_column_ref(Value *name)
{
	ColumnRef *cr = makeNode(ColumnRef);

	cr->fields = list_make1(name);
	return cr;
}
