/*-------------------------------------------------------------------------
 *
 * cdbwithingroupagg.c
 *	  Routines for rewriting within group agg to fit MPP database
 *
 * Portions Copyright (c) 2012-Present VMware, Inc. or its affiliates.
 *
 *
 * IDENTIFICATION
 *	    src/include/cdb/cdbwithingroupagg.h
 *
 *-------------------------------------------------------------------------
 */

extern bool        choose_mpp_within_group_agg(SelectStmt *stmt);
extern SelectStmt *cdb_rewrite_within_group_agg(SelectStmt *stmt);
