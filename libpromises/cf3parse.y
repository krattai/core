
%{

/*
   Copyright (C) Cfengine AS

   This file is part of Cfengine 3 - written and maintained by Cfengine AS.

   This program is free software; you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by the
   Free Software Foundation; version 3.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA

  To the extent this program is licensed as part of the Enterprise
  versions of Cfengine, the applicable Commerical Open Source License
  (COSL) may apply to this file if you as a licensee so wish it. See
  included file COSL.txt.
*/

#include "cf3.defs.h"
#include "parser_state.h"

#include "env_context.h"
#include "fncall.h"
#include "logging.h"
#include "rlist.h"
#include "item_lib.h"
#include "policy.h"
#include "mod_files.h"
#include "string_lib.h"

int yylex(void);

// FIX: remove
#include "syntax.h"

extern char *yytext;

static int RelevantBundle(const char *agent, const char *blocktype);
static void DebugBanner(const char *s);
static bool LvalWantsBody(char *stype, char *lval);
static SyntaxTypeMatch CheckSelection(const char *type, const char *name, const char *lval, Rval rval);
static SyntaxTypeMatch CheckConstraint(const char *type, const char *lval, Rval rval, PromiseTypeSyntax ss);
static void fatal_yyerror(const char *s);

static void ParseError(const char *s, ...) FUNC_ATTR_PRINTF(1, 2);

static bool INSTALL_SKIP = false;

#define YYMALLOC xmalloc

#define ParserDebug if (DEBUG) printf

%}

%token IDSYNTAX BLOCKID QSTRING CLASS PROMISE_TYPE BUNDLE BODY ASSIGN ARROW NAKEDVAR
%token OP CP OB CB

%%

specification:       /* empty */
                     | blocks

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

blocks:                block
                     | blocks block;

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

block:                 bundle
                     | body

bundle:                BUNDLE bundletype bundleid arglist bundlebody

body:                  BODY bodytype bodyid arglist bodybody

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

bundletype:            bundletype_values
                       {
                           DebugBanner("Bundle");
                           ParserDebug("P:bundle:%s\n", P.blocktype);
                           P.block = "bundle";
                           P.rval = (Rval) { NULL, '\0' };
                           RlistDestroy(P.currentRlist);
                           P.currentRlist = NULL;
                           P.currentstring = NULL;
                           strcpy(P.blockid,"");
                       }

bundletype_values:     typeid
                       {
                           /* FIXME: We keep it here, because we skip unknown
                            * promise bundles. Ought to be moved to
                            * after-parsing step once we know how to deal with
                            * it */

                           if (!BundleTypeCheck(P.blocktype))
                           {
                               ParseError("Unknown bundle type: %s", P.blocktype);
                               INSTALL_SKIP = true;
                           }
                       }
                     | error 
                       {
                           yyclearin;
                           ParseError("Expected bundle type, wrong input: %s", yytext);
                           INSTALL_SKIP = true;
                       }

bundleid:              bundleid_values
                       {
                          ParserDebug("\tP:bundle:%s:%s\n", P.blocktype, P.blockid);
                       }

bundleid_values:       blockid
                     | error 
                       {
                           yyclearin;
                           ParseError("Expected bundle id, wrong input:%s", yytext);
                           INSTALL_SKIP = true;
                       }

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

bodytype:              bodytype_values
                       {
                           DebugBanner("Body");
                           ParserDebug("P:body:%s\n", P.blocktype);
                           P.block = "body";
                           strcpy(P.blockid,"");
                           RlistDestroy(P.currentRlist);
                           P.currentRlist = NULL;
                           P.currentstring = NULL;
                       }

bodytype_values:       typeid
                       {
                           if (!BodyTypeCheck(P.blocktype))
                           {
                               ParseError("Unknown body type: %s", P.blocktype);
                           }
                       }
                     | error
                       {
                           yyclearin;
                           ParseError("Expected body type, wrong input: %s", yytext);
                       }

bodyid:                bodyid_values
                       {
                          ParserDebug("\tP:body:%s:%s\n", P.blocktype, P.blockid);
                       }

bodyid_values:         blockid
                     | error
                       {
                           yyclearin;
                           ParseError("Expected body id, wrong input:%s", yytext);
                           INSTALL_SKIP = true;
                       }

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

typeid:                IDSYNTAX
                       {
                           strncpy(P.blocktype,P.currentid,CF_MAXVARSIZE);
                           CfDebug("Found block type %s for %s\n",P.blocktype,P.block);

                           RlistDestroy(P.useargs);
                           P.useargs = NULL;
                       }

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

blockid:               IDSYNTAX
                       {
                           strncpy(P.blockid,P.currentid,CF_MAXVARSIZE);
                           P.offsets.last_block_id = P.offsets.last_id;
                           CfDebug("Found identifier %s for %s\n",P.currentid,P.block);
                       };

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

arglist:               /* Empty */ 
                     | arglist_begin aitems arglist_end
                     | arglist_begin arglist_end
                     | arglist_begin error
                       {
                          yyclearin;
                          ParseError("error in bundle function definition expected ), wrong input:%s", yytext);
                       }

arglist_begin:         OP
                       {
                           ParserDebug("P:%s:%s:%s arglist begin:%s\n", P.block,P.blocktype,P.blockid, yytext);
                       }

arglist_end:           CP
                       {
                           ParserDebug("P:%s:%s:%s arglist end:%s\n", P.block,P.blocktype,P.blockid, yytext);
                       }

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

aitems:                aitem
                     | aitems ',' aitem

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

aitem:                 IDSYNTAX  /* recipient of argument is never a literal */
                       {
                           ParserDebug("P:%s:%s:%s  arg id: %s\n", P.block,P.blocktype,P.blockid, P.currentid);
                           RlistAppendScalar(&(P.useargs),P.currentid);
                       }
                     | error
                       {
                          yyclearin;
                          ParseError("Expected id, wrong input:%s", yytext);
                       }

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

bundlebody:            body_begin
                       {
                           if (RelevantBundle(CF_AGENTTYPES[THIS_AGENT_TYPE], P.blocktype))
                           {
                               CfDebug("We a compiling everything here\n");
                               INSTALL_SKIP = false;
                           }
                           else if (strcmp(CF_AGENTTYPES[THIS_AGENT_TYPE], P.blocktype) != 0)
                           {
                               CfDebug("This is for a different agent\n");
                               INSTALL_SKIP = true;
                           }

                           if (!INSTALL_SKIP)
                           {
                               P.currentbundle = PolicyAppendBundle(P.policy, P.current_namespace, P.blockid, P.blocktype, P.useargs, P.filename);
                               P.currentbundle->offset.line = P.line_no;
                               P.currentbundle->offset.start = P.offsets.last_block_id;
                           }
                           else
                           {
                               P.currentbundle = NULL;
                           }

                           RlistDestroy(P.useargs);
                           P.useargs = NULL;
                       }

                       bundle_statements

                       CB 
                       {
                           INSTALL_SKIP = false;
                           P.offsets.last_id = -1;
                           P.offsets.last_string = -1;
                           P.offsets.last_class_id = -1;

                           if (P.currentbundle)
                           {
                               P.currentbundle->offset.end = P.offsets.current;
                           }
                           CfDebug("End promise bundle\n\n");
                       };

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

body_begin:            OB
                       {
                           ParserDebug("P:%s:%s:%s begin body open\n", P.block,P.blocktype,P.blockid);
                       }
                     | error
                       {
                           ParseError("Expected body open:{, wrong input:%s", yytext);
                       }


/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

bundle_statements:     /* empty */
                     | bundle_statement
                     | bundle_statements bundle_statement


/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

bundle_statement:      promise_type 
                     | promise_type classpromises
                     | promise_type error
                       {
                          yyclearin;
                          ParseError("Expected a class or promise statement, got:%s", yytext);
                       }

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

bodybody:              body_begin
                       {
                           P.currentbody = PolicyAppendBody(P.policy, P.current_namespace, P.blockid, P.blocktype, P.useargs, P.filename);
                           if (P.currentbody)
                           {
                               P.currentbody->offset.line = P.line_no;
                               P.currentbody->offset.start = P.offsets.last_block_id;
                           }

                           RlistDestroy(P.useargs);
                           P.useargs = NULL;

                           strcpy(P.currentid,"");
                           CfDebug("Starting block\n");
                       }

                       bodyattribs

                       CB 
                       {
                           P.offsets.last_id = -1;
                           P.offsets.last_string = -1;
                           P.offsets.last_class_id = -1;
                           if (P.currentbody)
                           {
                               P.currentbody->offset.end = P.offsets.current;
                           }
                           CfDebug("End promise body\n");
                       };

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

bodyattribs:           bodyattrib                    /* BODY ONLY */
                     | bodyattribs bodyattrib;

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

bodyattrib:            class
                     | selections;

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

selections:            selection                 /* BODY ONLY */
                     | selections selection;

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

selection:             id                         /* BODY ONLY */
                       ASSIGN
                       rval
                       {
                           {
                               SyntaxTypeMatch err = CheckSelection(P.blocktype, P.blockid, P.lval, P.rval);
                               if (err != SYNTAX_TYPE_MATCH_OK && err != SYNTAX_TYPE_MATCH_ERROR_UNEXPANDED)
                               {
                                   yyerror(SyntaxTypeMatchToString(err));
                               }
                           }

                           if (!INSTALL_SKIP)
                           {
                               Constraint *cp = NULL;

                               if (P.rval.type == RVAL_TYPE_SCALAR && strcmp(P.lval, "ifvarclass") == 0)
                               {
                                   ValidateClassSyntax(P.rval.item);
                               }

                               if (P.currentclasses == NULL)
                               {
                                   cp = BodyAppendConstraint(P.currentbody, P.lval, P.rval, "any", P.references_body);
                               }
                               else
                               {
                                   cp = BodyAppendConstraint(P.currentbody, P.lval, P.rval, P.currentclasses, P.references_body);
                               }
                               cp->offset.line = P.line_no;
                               cp->offset.start = P.offsets.last_id;
                               cp->offset.end = P.offsets.current;
                               cp->offset.context = P.offsets.last_class_id;
                           }
                           else
                           {
                               RvalDestroy(P.rval);
                           }

                           if (strcmp(P.blockid,"control") == 0 && strcmp(P.blocktype,"file") == 0)
                           {
                               if (strcmp(P.lval,"namespace") == 0)
                               {
                                   if (P.rval.type != RVAL_TYPE_SCALAR)
                                   {
                                       yyerror("namespace must be a constant scalar string");
                                   }
                                   else
                                   {
                                       free(P.current_namespace);
                                       P.current_namespace = xstrdup(P.rval.item);
                                   }
                               }
                           }
                           
                           P.rval = (Rval) { NULL, '\0' };
                       }
                       ';' ;

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

classpromises:         classpromise                     /* BUNDLE ONLY */
                     | classpromises classpromise


/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

classpromise:          class
                     | promises

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

promises:              promise_line             /* BUNDLE ONLY */
                     | promises promise_line

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

promise_type:          PROMISE_TYPE             /* BUNDLE ONLY */
                       {

                           CfDebug("\n* Begin new promise type %s in function \n\n",P.currenttype);
                           ParserDebug("\tP:%s:%s:%s promise_type = %s\n", P.block, P.blocktype, P.blockid, P.currenttype);

                           if (!PromiseTypeCheck(P.currenttype))
                           {
                               ParseError("Unknown promise type: %s", P.currenttype);
                               INSTALL_SKIP = true;
                           }

                           if (strcmp(P.block,"bundle") == 0)
                           {
                               if (!INSTALL_SKIP)
                               {
                                   P.currentstype = BundleAppendPromiseType(P.currentbundle,P.currenttype);
                                   P.currentstype->offset.line = P.line_no;
                                   P.currentstype->offset.start = P.offsets.last_promise_type_id;
                               }
                               else
                               {
                                   P.currentstype = NULL;
                               }
                           }
                       }
                     | error 
                       {
                          yyclearin;
                          ParseError("Expected promise type, got:%s", yytext);
                       }

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

promise_line:          promise ';'                   /* BUNDLE ONLY */
                     | promise error 
                       {
                          ParseError("Check previous statement for missing ;, got:%s", yytext);
                       }

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

promise:               promiser                    /* BUNDLE ONLY */

                       ARROW

                       rval            /* This is full form with rlist promisees */
                       {
                           if (!INSTALL_SKIP)
                           {
                               if (!P.currentstype)
                               {
                                   yyerror("Missing promise type declaration");
                               }

                               P.currentpromise = PromiseTypeAppendPromise(P.currentstype, P.promiser,
                                                                           P.rval,
                                                                           P.currentclasses ? P.currentclasses : "any");
                               P.currentpromise->offset.line = P.line_no;
                               P.currentpromise->offset.start = P.offsets.last_string;
                               P.currentpromise->offset.context = P.offsets.last_class_id;
                           }
                           else
                           {
                               P.currentpromise = NULL;
                           }
                       }

                       constraints
                       {
                           CfDebug("End implicit promise %s\n\n",P.promiser);
                           strcpy(P.currentid,"");
                           RlistDestroy(P.currentRlist);
                           P.currentRlist = NULL;
                           free(P.promiser);
                           if (P.currentstring)
                           {
                               free(P.currentstring);
                           }
                           P.currentstring = NULL;
                           P.promiser = NULL;
                           P.promisee = NULL;
                           /* reset argptrs etc*/
                       }

                       |

                       promiser
                       {
                           if (!INSTALL_SKIP)
                           {
                               if (!P.currentstype)
                               {
                                   yyerror("Missing promise type declaration");
                               }

                               P.currentpromise = PromiseTypeAppendPromise(P.currentstype, P.promiser,
                                                                (Rval) { NULL, RVAL_TYPE_NOPROMISEE },
                                                                P.currentclasses ? P.currentclasses : "any");
                               P.currentpromise->offset.line = P.line_no;
                               P.currentpromise->offset.start = P.offsets.last_string;
                               P.currentpromise->offset.context = P.offsets.last_class_id;
                           }
                           else
                           {
                               P.currentpromise = NULL;
                           }
                       }

                       constraints 
                       {
                           CfDebug("End full promise with promisee %s\n\n",P.promiser);

                           /* Don't free these */
                           strcpy(P.currentid,"");
                           RlistDestroy(P.currentRlist);
                           P.currentRlist = NULL;
                           free(P.promiser);
                           if (P.currentstring)
                           {
                               free(P.currentstring);
                           }
                           P.currentstring = NULL;
                           P.promiser = NULL;
                           P.promisee = NULL;
                           /* reset argptrs etc*/
                       }
                       ;

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

constraints:           constraint               /* BUNDLE ONLY */
                     | constraints ',' constraint
                     |;

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

constraint:            id                        /* BUNDLE ONLY */
                       ASSIGN
                       rval
                       {
                           if (!INSTALL_SKIP)
                           {
                               Constraint *cp = NULL;
                               PromiseTypeSyntax ss = PromiseTypeSyntaxLookup(P.blocktype,P.currenttype);
                               {
                                   SyntaxTypeMatch err = CheckConstraint(P.currenttype, P.lval, P.rval, ss);
                                   if (err != SYNTAX_TYPE_MATCH_OK && err != SYNTAX_TYPE_MATCH_ERROR_UNEXPANDED)
                                   {
                                       yyerror(SyntaxTypeMatchToString(err));
                                   }
                               }
                               if (P.rval.type == RVAL_TYPE_SCALAR && strcmp(P.lval, "ifvarclass") == 0)
                               {
                                   ValidateClassSyntax(P.rval.item);
                               }

                               cp = PromiseAppendConstraint(P.currentpromise, P.lval, P.rval, "any", P.references_body);
                               cp->offset.line = P.line_no;
                               cp->offset.start = P.offsets.last_id;
                               cp->offset.end = P.offsets.current;
                               cp->offset.context = P.offsets.last_class_id;
                               P.currentstype->offset.end = P.offsets.current;

                               // Cache whether there are subbundles for later $(this.promiser) logic

                               if (strcmp(P.lval,"usebundle") == 0 || strcmp(P.lval,"edit_line") == 0
                                   || strcmp(P.lval,"edit_xml") == 0)
                               {
                                   P.currentpromise->has_subbundles = true;
                               }

                               P.rval = (Rval) { NULL, '\0' };
                               strcpy(P.lval,"no lval");
                               RlistDestroy(P.currentRlist);
                               P.currentRlist = NULL;
                           }
                           else
                           {
                               RvalDestroy(P.rval);
                           }
                       };

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

class:                 CLASS
                       {
                           P.offsets.last_class_id = P.offsets.current - strlen(P.currentclasses) - 2;
                           ParserDebug("\tP:%s:%s:%s:%s class = %s\n", P.block, P.blocktype, P.blockid, P.currenttype, yytext);
                           CfDebug("  New class context \'%s\' :: \n\n",P.currentclasses);
                       };

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

id:                    IDSYNTAX
                       {
                           strncpy(P.lval,P.currentid,CF_MAXVARSIZE);
                           RlistDestroy(P.currentRlist);
                           P.currentRlist = NULL;
                           CfDebug("Recorded LVAL %s\n",P.lval);
                       };


/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

rval:                  IDSYNTAX
                       {
                           P.rval = (Rval) { xstrdup(P.currentid), RVAL_TYPE_SCALAR };
                           P.references_body = true;
                           CfDebug("Recorded IDRVAL %s\n", P.currentid);
                       }
                     | BLOCKID
                       {
                           P.rval = (Rval) { xstrdup(P.currentid), RVAL_TYPE_SCALAR };
                           P.references_body = true;
                           CfDebug("Recorded IDRVAL %s\n", P.currentid);
                       }
                     | QSTRING
                       {
                           P.rval = (Rval) { P.currentstring, RVAL_TYPE_SCALAR };
                           CfDebug("Recorded scalarRVAL %s\n", P.currentstring);

                           P.currentstring = NULL;
                           P.references_body = false;

                           if (P.currentpromise)
                           {
                               if (LvalWantsBody(P.currentpromise->parent_promise_type->name, P.lval))
                               {
                                   yyerror("An rvalue is quoted, but we expect an unquoted body identifier");
                               }
                           }
                       }
                     | NAKEDVAR
                       {
                           P.rval = (Rval) { P.currentstring, RVAL_TYPE_SCALAR };
                           CfDebug("Recorded saclarvariableRVAL %s\n", P.currentstring);

                           P.currentstring = NULL;
                           P.references_body = false;
                       }
                     | list
                       {
                           if (RlistLen(P.currentRlist) == 0)
                           {
                               RlistAppendScalar(&P.currentRlist, CF_NULL_VALUE);
                           }
                           P.rval = (Rval) { RlistCopy(P.currentRlist), RVAL_TYPE_LIST };
                           RlistDestroy(P.currentRlist);
                           P.currentRlist = NULL;
                           P.references_body = false;
                       }
                     | usefunction
                       {
                           P.rval = (Rval) { P.currentfncall[P.arg_nesting+1], RVAL_TYPE_FNCALL };
                           P.references_body = false;
                       };

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

list:                  OB CB 
                     | OB litems CB;

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

litems:                litems_int
                     | litems_int ',';

litems_int:            litem
                     | litems_int ',' litem;

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

litem:                 IDSYNTAX
                       {
                           RlistAppendScalar((Rlist **)&P.currentRlist, P.currentid);
                       }

                     | QSTRING
                       {
                           RlistAppendScalar((Rlist **)&P.currentRlist,(void *)P.currentstring);
                           free(P.currentstring);
                           P.currentstring = NULL;
                       }

                     | NAKEDVAR
                       {
                           RlistAppendScalar((Rlist **)&P.currentRlist,(void *)P.currentstring);
                           free(P.currentstring);
                           P.currentstring = NULL;
                       }

                     | usefunction
                       {
                           CfDebug("Install function call as list item from level %d\n",P.arg_nesting+1);
                           RlistAppendFnCall((Rlist **)&P.currentRlist,(void *)P.currentfncall[P.arg_nesting+1]);
                           FnCallDestroy(P.currentfncall[P.arg_nesting+1]);
                       };

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

functionid:            IDSYNTAX
                       {
                           CfDebug("Found function identifier %s\n",P.currentid);
                       }
                     | BLOCKID
                       {
                           CfDebug("Found qualified function identifier %s\n",P.currentid);
                       }
                     | NAKEDVAR
                       {
                           strncpy(P.currentid,P.currentstring,CF_MAXVARSIZE); // Make a var look like an ID
                           free(P.currentstring);
                           P.currentstring = NULL;
                           CfDebug("Found variable in place of a function identifier %s\n",P.currentid);
                       };

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

promiser:              QSTRING
                       {
                           P.promiser = P.currentstring;
                           P.currentstring = NULL;
                           CfDebug("Promising object name \'%s\'\n",P.promiser);
                       };

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

usefunction:           functionid givearglist
                       {
                           CfDebug("Finished with function call, now at level %d\n\n",P.arg_nesting);
                       };

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

givearglist:           OP 
                       {
                           ParserDebug("P:%s:%s:%s begin givearglist\n", P.block,P.blocktype,P.blockid);
                           if (++P.arg_nesting >= CF_MAX_NESTING)
                           {
                               fatal_yyerror("Nesting of functions is deeper than recommended");
                           }
                           P.currentfnid[P.arg_nesting] = xstrdup(P.currentid);
                           CfDebug("Start FnCall %s args level %d\n",P.currentfnid[P.arg_nesting],P.arg_nesting);
                       }

                       gaitems
                       CP 
                       {
                           ParserDebug("P:%s:%s:%s end givearglist\n", P.block,P.blocktype,P.blockid);
                           CfDebug("End args level %d\n",P.arg_nesting);
                           P.currentfncall[P.arg_nesting] = FnCallNew(P.currentfnid[P.arg_nesting],P.giveargs[P.arg_nesting]);
                           P.giveargs[P.arg_nesting] = NULL;
                           strcpy(P.currentid,"");
                           free(P.currentfnid[P.arg_nesting]);
                           P.currentfnid[P.arg_nesting] = NULL;
                           P.arg_nesting--;
                       };


/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

gaitems:               gaitem
                     | gaitems ',' gaitem
                     |;

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

gaitem:                IDSYNTAX
                       {
                           /* currently inside a use function */
                           RlistAppendScalar(&P.giveargs[P.arg_nesting],P.currentid);
                       }

                     | QSTRING
                       {
                           /* currently inside a use function */
                           RlistAppendScalar(&P.giveargs[P.arg_nesting],P.currentstring);
                           free(P.currentstring);
                           P.currentstring = NULL;
                       }

                     | NAKEDVAR
                       {
                           /* currently inside a use function */
                           RlistAppendScalar(&P.giveargs[P.arg_nesting],P.currentstring);
                           free(P.currentstring);
                           P.currentstring = NULL;
                       }

                     | usefunction
                       {
                           /* Careful about recursion */
                           RlistAppendFnCall(&P.giveargs[P.arg_nesting],(void *)P.currentfncall[P.arg_nesting+1]);
                           RvalDestroy((Rval) { P.currentfncall[P.arg_nesting+1], RVAL_TYPE_FNCALL });
                       };

%%

/*****************************************************************/

static void ParseErrorV(const char *s, va_list ap)
{
    char *errmsg = StringVFormat(s, ap);

    fprintf(stderr, "%s:%d:%d: error: %s\n", P.filename, P.line_no, P.line_pos, errmsg);
    fprintf(stderr, "%s\n", P.current_line);
    fprintf(stderr, "%*s\n", P.line_pos, "^");

    free(errmsg);

    P.error_count++;

    if (P.error_count > 10)
    {
        fprintf(stderr, "Too many errors");
        exit(1);
    }
}

static void ParseError(const char *s, ...)
{
    va_list ap;
    va_start(ap, s);
    ParseErrorV(s, ap);
    va_end(ap);
}

void yyerror(const char *str)
{
    ParseError("%s", str);
}

static void fatal_yyerror(const char *s)
{
    char *sp = yytext;
    /* Skip quotation mark */
    if (sp && *sp == '\"' && sp[1])
    {
        sp++;
    }

    fprintf(stderr, "%s: %d,%d: Fatal error during parsing: %s, near token \'%.20s\'\n", P.filename, P.line_no, P.line_pos, s, sp ? sp : "NULL");
    exit(1);
}

static void DebugBanner(const char *s)
{
    CfDebug("----------------------------------------------------------------\n");
    CfDebug("  %s                                                            \n", s);
    CfDebug("----------------------------------------------------------------\n");
}

static int RelevantBundle(const char *agent, const char *blocktype)
{
    Item *ip;

    if ((strcmp(agent, CF_AGENTTYPES[AGENT_TYPE_COMMON]) == 0) || (strcmp(CF_COMMONC, blocktype) == 0))
    {
        return true;
    }

/* Here are some additional bundle types handled by cfAgent */

    ip = SplitString("edit_line,edit_xml", ',');

    if (strcmp(agent, CF_AGENTTYPES[AGENT_TYPE_AGENT]) == 0)
    {
        if (IsItemIn(ip, blocktype))
        {
            DeleteItemList(ip);
            return true;
        }
    }

    DeleteItemList(ip);
    return false;
}

static bool LvalWantsBody(char *stype, char *lval)
{
    int i, j, l;
    const PromiseTypeSyntax *ss;
    const ConstraintSyntax *bs;

    for (i = 0; i < CF3_MODULES; i++)
    {
        if ((ss = CF_ALL_PROMISE_TYPES[i]) == NULL)
        {
            continue;
        }

        for (j = 0; ss[j].promise_type != NULL; j++)
        {
            if ((bs = ss[j].bs) == NULL)
            {
                continue;
            }

            if (strcmp(ss[j].promise_type, stype) != 0)
            {
                continue;
            }

            for (l = 0; bs[l].range != NULL; l++)
            {
                if (strcmp(bs[l].lval, lval) == 0)
                {
                    if (bs[l].dtype == DATA_TYPE_BODY)
                    {
                        return true;
                    }
                    else
                    {
                        return false;
                    }
                }
            }
        }
    }

    return false;
}

static SyntaxTypeMatch CheckSelection(const char *type, const char *name, const char *lval, Rval rval)
{
    int lmatch = false;
    int i, j, k, l;
    const PromiseTypeSyntax *ss;
    const ConstraintSyntax *bs, *bs2;
    char output[CF_BUFSIZE];

    CfDebug("CheckSelection(%s,%s,", type, lval);

    if (DEBUG)
    {
        RvalShow(stdout, rval);
    }

    CfDebug(")\n");

/* Check internal control bodies etc */

    for (i = 0; CF_ALL_BODIES[i].promise_type != NULL; i++)
    {
        if (strcmp(CF_ALL_BODIES[i].promise_type, name) == 0 && strcmp(type, CF_ALL_BODIES[i].bundle_type) == 0)
        {
            CfDebug("Found matching a body matching (%s,%s)\n", type, name);

            bs = CF_ALL_BODIES[i].bs;

            for (l = 0; bs[l].lval != NULL; l++)
            {
                if (strcmp(lval, bs[l].lval) == 0)
                {
                    CfDebug("Matched syntatically correct body (lval) item = (%s)\n", lval);

                    if (bs[l].dtype == DATA_TYPE_BODY)
                    {
                        CfDebug("Constraint syntax ok, but definition of body is elsewhere\n");
                        return SYNTAX_TYPE_MATCH_OK;
                    }
                    else if (bs[l].dtype == DATA_TYPE_BUNDLE)
                    {
                        CfDebug("Constraint syntax ok, but definition of bundle is elsewhere\n");
                        return SYNTAX_TYPE_MATCH_OK;
                    }
                    else
                    {
                        return CheckConstraintTypeMatch(lval, rval, bs[l].dtype, (char *) (bs[l].range), 0);
                    }
                }
            }

        }
    }

/* Now check the functional modules - extra level of indirection */

    for (i = 0; i < CF3_MODULES; i++)
    {
        CfDebug("Trying function module %d for matching lval %s\n", i, lval);

        if ((ss = CF_ALL_PROMISE_TYPES[i]) == NULL)
        {
            continue;
        }

        for (j = 0; ss[j].promise_type != NULL; j++)
        {
            if ((bs = ss[j].bs) == NULL)
            {
                continue;
            }

            CfDebug("\nExamining promise_type %s\n", ss[j].promise_type);

            for (l = 0; bs[l].range != NULL; l++)
            {
                if (bs[l].dtype == DATA_TYPE_BODY)
                {
                    bs2 = (const ConstraintSyntax *) (bs[l].range);

                    if (bs2 == NULL || bs2 == (void *) CF_BUNDLE)
                    {
                        continue;
                    }

                    for (k = 0; bs2[k].dtype != DATA_TYPE_NONE; k++)
                    {
                        /* Either module defined or common */

                        if (strcmp(ss[j].promise_type, type) == 0 && strcmp(ss[j].promise_type, "*") != 0)
                        {
                            snprintf(output, CF_BUFSIZE, "lval %s belongs to promise type \'%s:\' but this is '\%s\'\n",
                                     lval, ss[j].promise_type, type);
                            yyerror(output);
                            return SYNTAX_TYPE_MATCH_OK;
                        }

                        if (strcmp(lval, bs2[k].lval) == 0)
                        {
                            CfDebug("Matched\n");
                            return CheckConstraintTypeMatch(lval, rval, bs2[k].dtype, (char *) (bs2[k].range), 0);
                        }
                    }
                }
            }
        }
    }

    if (!lmatch)
    {
        snprintf(output, CF_BUFSIZE, "Constraint lvalue \"%s\" is not allowed in \'%s\' constraint body", lval, type);
        yyerror(output);
    }

    return SYNTAX_TYPE_MATCH_OK;
}

static SyntaxTypeMatch CheckConstraint(const char *type, const char *lval, Rval rval, PromiseTypeSyntax ss)
{
    int l;
    const ConstraintSyntax *bs;

    CfDebug("CheckConstraint(%s,%s,", type, lval);

    if (DEBUG)
    {
        RvalShow(stdout, rval);
    }

    CfDebug(")\n");

    if (ss.promise_type != NULL)     /* In a bundle */
    {
        if (strcmp(ss.promise_type, type) == 0)
        {
            CfDebug("Found type %s's body syntax\n", type);

            bs = ss.bs;

            for (l = 0; bs[l].lval != NULL; l++)
            {
                CfDebug("CMP-bundle # (%s,%s)\n", lval, bs[l].lval);

                if (strcmp(lval, bs[l].lval) == 0)
                {
                    /* If we get here we have found the lval and it is valid
                       for this promise_type */
                    CfDebug("Matched syntatically correct bundle (lval,rval) item = (%s) to its rval\n", lval);

                    /* For bodies and bundles definitions can be elsewhere, so
                       they are checked in PolicyCheckRunnable(). */
                    if (bs[l].dtype != DATA_TYPE_BODY &&
                        bs[l].dtype != DATA_TYPE_BUNDLE)
                    {
                        return CheckConstraintTypeMatch(lval, rval, bs[l].dtype,
                                                        (char *) bs[l].range, 0);
                    }
                }
            }
        }
    }

    return SYNTAX_TYPE_MATCH_OK;
}