/* header */
/* src/interfaces/ecpg/preproc/ecpg.header */

/* Copyright comment */
%{
#include "postgres_fe.h"

#include "preproc_extern.h"
#include "ecpg_config.h"
#include <unistd.h>

/* Location tracking support --- simpler than bison's default */
#define YYLLOC_DEFAULT(Current, Rhs, N) \
	do { \
		if (N)						\
			(Current) = (Rhs)[1];	\
		else						\
			(Current) = (Rhs)[0];	\
	} while (0)

/*
 * The %name-prefix option below will make bison call base_yylex, but we
 * really want it to call filtered_base_yylex (see parser.c).
 */
#define base_yylex filtered_base_yylex

/*
 * This is only here so the string gets into the POT.  Bison uses it
 * internally.
 */
#define bison_gettext_dummy gettext_noop("syntax error")

/*
 * Variables containing simple states.
 */
int struct_level = 0;
int braces_open; /* brace level counter */
char *current_function;
int ecpg_internal_var = 0;
char	*connection = NULL;
char	*input_filename = NULL;

static int	FoundInto = 0;
static int	initializer = 0;
static int	pacounter = 1;
static char	pacounter_buffer[sizeof(int) * CHAR_BIT * 10 / 3]; /* a rough guess at the size we need */
static struct this_type actual_type[STRUCT_DEPTH];
static char *actual_startline[STRUCT_DEPTH];
static int	varchar_counter = 1;
static int	bytea_counter = 1;

/* temporarily store struct members while creating the data structure */
struct ECPGstruct_member *struct_member_list[STRUCT_DEPTH] = { NULL };

/* also store struct type so we can do a sizeof() later */
static char *ECPGstruct_sizeof = NULL;

/* for forward declarations we have to store some data as well */
static char *forward_name = NULL;

struct ECPGtype ecpg_no_indicator = {ECPGt_NO_INDICATOR, NULL, NULL, NULL, {NULL}, 0};
struct variable no_indicator = {"no_indicator", &ecpg_no_indicator, 0, NULL};

static struct ECPGtype ecpg_query = {ECPGt_char_variable, NULL, NULL, NULL, {NULL}, 0};

static void vmmerror(int error_code, enum errortype type, const char *error, va_list ap) pg_attribute_printf(3, 0);

static bool check_declared_list(const char*);

/*
 * Handle parsing errors and warnings
 */
static void
vmmerror(int error_code, enum errortype type, const char *error, va_list ap)
{
	/* localize the error message string */
	error = _(error);

	fprintf(stderr, "%s:%d: ", input_filename, base_yylineno);

	switch(type)
	{
		case ET_WARNING:
			fprintf(stderr, _("WARNING: "));
			break;
		case ET_ERROR:
			fprintf(stderr, _("ERROR: "));
			break;
	}

	vfprintf(stderr, error, ap);

	fprintf(stderr, "\n");

	switch(type)
	{
		case ET_WARNING:
			break;
		case ET_ERROR:
			ret_value = error_code;
			break;
	}
}

void
mmerror(int error_code, enum errortype type, const char *error, ...)
{
	va_list		ap;

	va_start(ap, error);
	vmmerror(error_code, type, error, ap);
	va_end(ap);
}

void
mmfatal(int error_code, const char *error, ...)
{
	va_list		ap;

	va_start(ap, error);
	vmmerror(error_code, ET_ERROR, error, ap);
	va_end(ap);

	if (base_yyin)
		fclose(base_yyin);
	if (base_yyout)
		fclose(base_yyout);

	if (strcmp(output_filename, "-") != 0 && unlink(output_filename) != 0)
		fprintf(stderr, _("could not remove output file \"%s\"\n"), output_filename);
	exit(error_code);
}

/*
 * string concatenation
 */

static char *
cat2_str(char *str1, char *str2)
{
	char * res_str	= (char *)mm_alloc(strlen(str1) + strlen(str2) + 2);

	strcpy(res_str, str1);
	if (strlen(str1) != 0 && strlen(str2) != 0)
		strcat(res_str, " ");
	strcat(res_str, str2);
	free(str1);
	free(str2);
	return res_str;
}

static char *
cat_str(int count, ...)
{
	va_list		args;
	int			i;
	char		*res_str;

	va_start(args, count);

	res_str = va_arg(args, char *);

	/* now add all other strings */
	for (i = 1; i < count; i++)
		res_str = cat2_str(res_str, va_arg(args, char *));

	va_end(args);

	return res_str;
}

static char *
make2_str(char *str1, char *str2)
{
	char * res_str	= (char *)mm_alloc(strlen(str1) + strlen(str2) + 1);

	strcpy(res_str, str1);
	strcat(res_str, str2);
	free(str1);
	free(str2);
	return res_str;
}

static char *
make3_str(char *str1, char *str2, char *str3)
{
	char * res_str	= (char *)mm_alloc(strlen(str1) + strlen(str2) +strlen(str3) + 1);

	strcpy(res_str, str1);
	strcat(res_str, str2);
	strcat(res_str, str3);
	free(str1);
	free(str2);
	free(str3);
	return res_str;
}

/* and the rest */
static char *
make_name(void)
{
	return mm_strdup(base_yytext);
}

static char *
create_questionmarks(char *name, bool array)
{
	struct variable *p = find_variable(name);
	int count;
	char *result = EMPTY;

	/* In case we have a struct, we have to print as many "?" as there are attributes in the struct
	 * An array is only allowed together with an element argument
	 * This is essentially only used for inserts, but using a struct as input parameter is an error anywhere else
	 * so we don't have to worry here. */

	if (p->type->type == ECPGt_struct || (array && p->type->type == ECPGt_array && p->type->u.element->type == ECPGt_struct))
	{
		struct ECPGstruct_member *m;

		if (p->type->type == ECPGt_struct)
			m = p->type->u.members;
		else
			m = p->type->u.element->u.members;

		for (count = 0; m != NULL; m=m->next, count++);
	}
	else
		count = 1;

	for (; count > 0; count --)
	{
		sprintf(pacounter_buffer, "$%d", pacounter++);
		result = cat_str(3, result, mm_strdup(pacounter_buffer), mm_strdup(" , "));
	}

	/* removed the trailing " ," */

	result[strlen(result)-3] = '\0';
	return result;
}

static char *
adjust_outofscope_cursor_vars(struct cursor *cur)
{
	/* Informix accepts DECLARE with variables that are out of scope when OPEN is called.
	 * For instance you can DECLARE a cursor in one function, and OPEN/FETCH/CLOSE
	 * it in another functions. This is very useful for e.g. event-driver programming,
	 * but may also lead to dangerous programming. The limitation when this is allowed
	 * and doesn't cause problems have to be documented, like the allocated variables
	 * must not be realloc()'ed.
	 *
	 * We have to change the variables to our own struct and just store the pointer
	 * instead of the variable. Do it only for local variables, not for globals.
	 */

	char *result = EMPTY;
	int insert;

	for (insert = 1; insert >= 0; insert--)
	{
		struct arguments *list;
		struct arguments *ptr;
		struct arguments *newlist = NULL;
		struct variable *newvar, *newind;

		list = (insert ? cur->argsinsert : cur->argsresult);

		for (ptr = list; ptr != NULL; ptr = ptr->next)
		{
			char var_text[20];
			char *original_var;
			bool skip_set_var = false;
			bool var_ptr = false;

			/* change variable name to "ECPGget_var(<counter>)" */
			original_var = ptr->variable->name;
			sprintf(var_text, "%d))", ecpg_internal_var);

			/* Don't emit ECPGset_var() calls for global variables */
			if (ptr->variable->brace_level == 0)
			{
				newvar = ptr->variable;
				skip_set_var = true;
			}
			else if ((ptr->variable->type->type == ECPGt_char_variable)
					 && (strncmp(ptr->variable->name, "ECPGprepared_statement", strlen("ECPGprepared_statement")) == 0))
			{
				newvar = ptr->variable;
				skip_set_var = true;
			}
			else if ((ptr->variable->type->type != ECPGt_varchar
					  && ptr->variable->type->type != ECPGt_char
					  && ptr->variable->type->type != ECPGt_unsigned_char
					  && ptr->variable->type->type != ECPGt_string
					  && ptr->variable->type->type != ECPGt_bytea)
					 && atoi(ptr->variable->type->size) > 1)
			{
				newvar = new_variable(cat_str(4, mm_strdup("("),
											  mm_strdup(ecpg_type_name(ptr->variable->type->u.element->type)),
											  mm_strdup(" *)(ECPGget_var("),
											  mm_strdup(var_text)),
									  ECPGmake_array_type(ECPGmake_simple_type(ptr->variable->type->u.element->type,
																			   mm_strdup("1"),
																			   ptr->variable->type->u.element->counter),
														  ptr->variable->type->size),
									  0);
			}
			else if ((ptr->variable->type->type == ECPGt_varchar
					  || ptr->variable->type->type == ECPGt_char
					  || ptr->variable->type->type == ECPGt_unsigned_char
					  || ptr->variable->type->type == ECPGt_string
					  || ptr->variable->type->type == ECPGt_bytea)
					 && atoi(ptr->variable->type->size) > 1)
			{
				newvar = new_variable(cat_str(4, mm_strdup("("),
											  mm_strdup(ecpg_type_name(ptr->variable->type->type)),
											  mm_strdup(" *)(ECPGget_var("),
											  mm_strdup(var_text)),
									  ECPGmake_simple_type(ptr->variable->type->type,
														   ptr->variable->type->size,
														   ptr->variable->type->counter),
									  0);
				if (ptr->variable->type->type == ECPGt_varchar ||
					ptr->variable->type->type == ECPGt_bytea)
					var_ptr = true;
			}
			else if (ptr->variable->type->type == ECPGt_struct
					 || ptr->variable->type->type == ECPGt_union)
			{
				newvar = new_variable(cat_str(5, mm_strdup("(*("),
											  mm_strdup(ptr->variable->type->type_name),
											  mm_strdup(" *)(ECPGget_var("),
											  mm_strdup(var_text),
											  mm_strdup(")")),
									  ECPGmake_struct_type(ptr->variable->type->u.members,
														   ptr->variable->type->type,
														   ptr->variable->type->type_name,
														   ptr->variable->type->struct_sizeof),
									  0);
				var_ptr = true;
			}
			else if (ptr->variable->type->type == ECPGt_array)
			{
				if (ptr->variable->type->u.element->type == ECPGt_struct
					|| ptr->variable->type->u.element->type == ECPGt_union)
				{
					newvar = new_variable(cat_str(5, mm_strdup("(*("),
											  mm_strdup(ptr->variable->type->u.element->type_name),
											  mm_strdup(" *)(ECPGget_var("),
											  mm_strdup(var_text),
											  mm_strdup(")")),
										  ECPGmake_struct_type(ptr->variable->type->u.element->u.members,
															   ptr->variable->type->u.element->type,
															   ptr->variable->type->u.element->type_name,
															   ptr->variable->type->u.element->struct_sizeof),
										  0);
				}
				else
				{
					newvar = new_variable(cat_str(4, mm_strdup("("),
												  mm_strdup(ecpg_type_name(ptr->variable->type->u.element->type)),
												  mm_strdup(" *)(ECPGget_var("),
												  mm_strdup(var_text)),
										  ECPGmake_array_type(ECPGmake_simple_type(ptr->variable->type->u.element->type,
																				   ptr->variable->type->u.element->size,
																				   ptr->variable->type->u.element->counter),
															  ptr->variable->type->size),
										  0);
					var_ptr = true;
				}
			}
			else
			{
				newvar = new_variable(cat_str(4, mm_strdup("*("),
											  mm_strdup(ecpg_type_name(ptr->variable->type->type)),
											  mm_strdup(" *)(ECPGget_var("),
											  mm_strdup(var_text)),
									  ECPGmake_simple_type(ptr->variable->type->type,
														   ptr->variable->type->size,
														   ptr->variable->type->counter),
									  0);
				var_ptr = true;
			}

			/* create call to "ECPGset_var(<counter>, <connection>, <pointer>. <line number>)" */
			if (!skip_set_var)
			{
				sprintf(var_text, "%d, %s", ecpg_internal_var++, var_ptr ? "&(" : "(");
				result = cat_str(5, result, mm_strdup("ECPGset_var("),
								 mm_strdup(var_text), mm_strdup(original_var),
								 mm_strdup("), __LINE__);\n"));
			}

			/* now the indicator if there is one and it's not a global variable */
			if ((ptr->indicator->type->type == ECPGt_NO_INDICATOR) || (ptr->indicator->brace_level == 0))
			{
				newind = ptr->indicator;
			}
			else
			{
				/* change variable name to "ECPGget_var(<counter>)" */
				original_var = ptr->indicator->name;
				sprintf(var_text, "%d))", ecpg_internal_var);
				var_ptr = false;

				if (ptr->indicator->type->type == ECPGt_struct
					|| ptr->indicator->type->type == ECPGt_union)
				{
					newind = new_variable(cat_str(5, mm_strdup("(*("),
											  mm_strdup(ptr->indicator->type->type_name),
											  mm_strdup(" *)(ECPGget_var("),
											  mm_strdup(var_text),
											  mm_strdup(")")),
										  ECPGmake_struct_type(ptr->indicator->type->u.members,
															   ptr->indicator->type->type,
															   ptr->indicator->type->type_name,
															   ptr->indicator->type->struct_sizeof),
										  0);
					var_ptr = true;
				}
				else if (ptr->indicator->type->type == ECPGt_array)
				{
					if (ptr->indicator->type->u.element->type == ECPGt_struct
						|| ptr->indicator->type->u.element->type == ECPGt_union)
					{
						newind = new_variable(cat_str(5, mm_strdup("(*("),
											  mm_strdup(ptr->indicator->type->u.element->type_name),
											  mm_strdup(" *)(ECPGget_var("),
											  mm_strdup(var_text),
											  mm_strdup(")")),
											  ECPGmake_struct_type(ptr->indicator->type->u.element->u.members,
																   ptr->indicator->type->u.element->type,
																   ptr->indicator->type->u.element->type_name,
																   ptr->indicator->type->u.element->struct_sizeof),
											  0);
					}
					else
					{
						newind = new_variable(cat_str(4, mm_strdup("("),
													  mm_strdup(ecpg_type_name(ptr->indicator->type->u.element->type)),
													  mm_strdup(" *)(ECPGget_var("), mm_strdup(var_text)),
											  ECPGmake_array_type(ECPGmake_simple_type(ptr->indicator->type->u.element->type,
																					   ptr->indicator->type->u.element->size,
																					   ptr->indicator->type->u.element->counter),
																  ptr->indicator->type->size),
											  0);
						var_ptr = true;
					}
				}
				else if (atoi(ptr->indicator->type->size) > 1)
				{
					newind = new_variable(cat_str(4, mm_strdup("("),
												  mm_strdup(ecpg_type_name(ptr->indicator->type->type)),
												  mm_strdup(" *)(ECPGget_var("),
												  mm_strdup(var_text)),
										  ECPGmake_simple_type(ptr->indicator->type->type,
															   ptr->indicator->type->size,
															   ptr->variable->type->counter),
										  0);
				}
				else
				{
					newind = new_variable(cat_str(4, mm_strdup("*("),
												  mm_strdup(ecpg_type_name(ptr->indicator->type->type)),
												  mm_strdup(" *)(ECPGget_var("),
												  mm_strdup(var_text)),
										  ECPGmake_simple_type(ptr->indicator->type->type,
															   ptr->indicator->type->size,
															   ptr->variable->type->counter),
										  0);
					var_ptr = true;
				}

				/* create call to "ECPGset_var(<counter>, <pointer>. <line number>)" */
				sprintf(var_text, "%d, %s", ecpg_internal_var++, var_ptr ? "&(" : "(");
				result = cat_str(5, result, mm_strdup("ECPGset_var("),
								 mm_strdup(var_text), mm_strdup(original_var),
								 mm_strdup("), __LINE__);\n"));
			}

			add_variable_to_tail(&newlist, newvar, newind);
		}

		if (insert)
			cur->argsinsert_oos = newlist;
		else
			cur->argsresult_oos = newlist;
	}

	return result;
}

/* This tests whether the cursor was declared and opened in the same function. */
#define SAMEFUNC(cur)	\
	((cur->function == NULL) ||		\
	 (cur->function != NULL && strcmp(cur->function, current_function) == 0))

static struct cursor *
add_additional_variables(char *name, bool insert)
{
	struct cursor *ptr;
	struct arguments *p;
	int (* strcmp_fn)(const char *, const char *) = ((name[0] == ':' || name[0] == '"') ? strcmp : pg_strcasecmp);

	for (ptr = cur; ptr != NULL; ptr=ptr->next)
	{
		if (strcmp_fn(ptr->name, name) == 0)
			break;
	}

	if (ptr == NULL)
	{
		mmerror(PARSE_ERROR, ET_ERROR, "cursor \"%s\" does not exist", name);
		return NULL;
	}

	if (insert)
	{
		/* add all those input variables that were given earlier
		 * note that we have to append here but have to keep the existing order */
		for (p = (SAMEFUNC(ptr) ? ptr->argsinsert : ptr->argsinsert_oos); p; p = p->next)
			add_variable_to_tail(&argsinsert, p->variable, p->indicator);
	}

	/* add all those output variables that were given earlier */
	for (p = (SAMEFUNC(ptr) ? ptr->argsresult : ptr->argsresult_oos); p; p = p->next)
		add_variable_to_tail(&argsresult, p->variable, p->indicator);

	return ptr;
}

static void
add_typedef(char *name, char *dimension, char *length, enum ECPGttype type_enum,
			char *type_dimension, char *type_index, int initializer, int array)
{
	/* add entry to list */
	struct typedefs *ptr, *this;

	if ((type_enum == ECPGt_struct ||
		 type_enum == ECPGt_union) &&
		initializer == 1)
		mmerror(PARSE_ERROR, ET_ERROR, "initializer not allowed in type definition");
	else if (INFORMIX_MODE && strcmp(name, "string") == 0)
		mmerror(PARSE_ERROR, ET_ERROR, "type name \"string\" is reserved in Informix mode");
	else
	{
		for (ptr = types; ptr != NULL; ptr = ptr->next)
		{
			if (strcmp(name, ptr->name) == 0)
				/* re-definition is a bug */
				mmerror(PARSE_ERROR, ET_ERROR, "type \"%s\" is already defined", name);
		}
		adjust_array(type_enum, &dimension, &length, type_dimension, type_index, array, true);

		this = (struct typedefs *) mm_alloc(sizeof(struct typedefs));

		/* initial definition */
		this->next = types;
		this->name = name;
		this->brace_level = braces_open;
		this->type = (struct this_type *) mm_alloc(sizeof(struct this_type));
		this->type->type_enum = type_enum;
		this->type->type_str = mm_strdup(name);
		this->type->type_dimension = dimension; /* dimension of array */
		this->type->type_index = length;	/* length of string */
		this->type->type_sizeof = ECPGstruct_sizeof;
		this->struct_member_list = (type_enum == ECPGt_struct || type_enum == ECPGt_union) ?
		ECPGstruct_member_dup(struct_member_list[struct_level]) : NULL;

		if (type_enum != ECPGt_varchar &&
			type_enum != ECPGt_bytea &&
			type_enum != ECPGt_char &&
			type_enum != ECPGt_unsigned_char &&
			type_enum != ECPGt_string &&
			atoi(this->type->type_index) >= 0)
			mmerror(PARSE_ERROR, ET_ERROR, "multidimensional arrays for simple data types are not supported");

		types = this;
	}
}

/*
 * check an SQL identifier is declared or not.
 * If it is already declared, the global variable
 * connection will be changed to the related connection.
 */
static bool
check_declared_list(const char *name)
{
	struct declared_list *ptr = NULL;
	for (ptr = g_declared_list; ptr != NULL; ptr = ptr -> next)
	{
		if (!ptr->connection)
			continue;
		if (strcmp(name, ptr -> name) == 0)
		{
			if (connection && strcmp(ptr->connection, connection) != 0)
				mmerror(PARSE_ERROR, ET_WARNING, "connection %s is overwritten with %s by DECLARE statement %s", connection, ptr->connection, name);
			connection = mm_strdup(ptr -> connection);
			return true;
		}
	}
	return false;
}
%}

%expect 0
%name-prefix="base_yy"
%locations

%union {
	double	dval;
	char	*str;
	int		ival;
	struct	when		action;
	struct	index		index;
	int		tagname;
	struct	this_type	type;
	enum	ECPGttype	type_enum;
	enum	ECPGdtype	dtype_enum;
	struct	fetch_desc	descriptor;
	struct  su_symbol	struct_union;
	struct	prep		prep;
	struct	exec		exec;
	struct describe		describe;
}
/* tokens */
/* src/interfaces/ecpg/preproc/ecpg.tokens */

/* special embedded SQL tokens */
%token  SQL_ALLOCATE SQL_AUTOCOMMIT SQL_BOOL SQL_BREAK
                SQL_CARDINALITY SQL_CONNECT
                SQL_COUNT
                SQL_DATETIME_INTERVAL_CODE
                SQL_DATETIME_INTERVAL_PRECISION SQL_DESCRIBE
                SQL_DESCRIPTOR SQL_DISCONNECT SQL_FOUND
                SQL_FREE SQL_GET SQL_GO SQL_GOTO SQL_IDENTIFIED
                SQL_INDICATOR SQL_KEY_MEMBER SQL_LENGTH
                SQL_LONG SQL_NULLABLE SQL_OCTET_LENGTH
                SQL_OPEN SQL_OUTPUT SQL_REFERENCE
                SQL_RETURNED_LENGTH SQL_RETURNED_OCTET_LENGTH SQL_SCALE
                SQL_SECTION SQL_SHORT SQL_SIGNED SQL_SQLERROR
                SQL_SQLPRINT SQL_SQLWARNING SQL_START SQL_STOP
                SQL_STRUCT SQL_UNSIGNED SQL_VAR SQL_WHENEVER

/* C tokens */
%token  S_ADD S_AND S_ANYTHING S_AUTO S_CONST S_DEC S_DIV
                S_DOTPOINT S_EQUAL S_EXTERN S_INC S_LSHIFT S_MEMPOINT
                S_MEMBER S_MOD S_MUL S_NEQUAL S_OR S_REGISTER S_RSHIFT
                S_STATIC S_SUB S_VOLATILE
                S_TYPEDEF

%token CSTRING CVARIABLE CPP_LINE IP
/* types */
%type <str> toplevel_stmt
%type <str> stmt
%type <str> CallStmt
%type <str> CreateRoleStmt
%type <str> opt_with
%type <str> OptRoleList
%type <str> AlterOptRoleList
%type <str> AlterOptRoleElem
%type <str> CreateOptRoleElem
%type <str> CreateUserStmt
%type <str> AlterRoleStmt
%type <str> opt_in_database
%type <str> AlterRoleSetStmt
%type <str> DropRoleStmt
%type <str> CreateGroupStmt
%type <str> AlterGroupStmt
%type <str> add_drop
%type <str> CreateSchemaStmt
%type <str> OptSchemaName
%type <str> OptSchemaEltList
%type <str> schema_stmt
%type <str> VariableSetStmt
%type <str> set_rest
%type <str> generic_set
%type <str> set_rest_more
%type <str> var_name
%type <str> var_list
%type <str> var_value
%type <str> iso_level
%type <str> opt_boolean_or_string
%type <str> zone_value
%type <str> opt_encoding
%type <str> NonReservedWord_or_Sconst
%type <str> VariableResetStmt
%type <str> reset_rest
%type <str> generic_reset
%type <str> SetResetClause
%type <str> FunctionSetResetClause
%type <str> VariableShowStmt
%type <str> ConstraintsSetStmt
%type <str> constraints_set_list
%type <str> constraints_set_mode
%type <str> CheckPointStmt
%type <str> DiscardStmt
%type <str> AlterTableStmt
%type <str> alter_table_cmds
%type <str> partition_cmd
%type <str> index_partition_cmd
%type <str> alter_table_cmd
%type <str> alter_column_default
%type <str> opt_drop_behavior
%type <str> opt_collate_clause
%type <str> alter_using
%type <str> replica_identity
%type <str> reloptions
%type <str> opt_reloptions
%type <str> reloption_list
%type <str> reloption_elem
%type <str> alter_identity_column_option_list
%type <str> alter_identity_column_option
%type <str> PartitionBoundSpec
%type <str> hash_partbound_elem
%type <str> hash_partbound
%type <str> AlterCompositeTypeStmt
%type <str> alter_type_cmds
%type <str> alter_type_cmd
%type <str> ClosePortalStmt
%type <str> CopyStmt
%type <str> copy_from
%type <str> opt_program
%type <str> copy_file_name
%type <str> copy_options
%type <str> copy_opt_list
%type <str> copy_opt_item
%type <str> opt_binary
%type <str> copy_delimiter
%type <str> opt_using
%type <str> copy_generic_opt_list
%type <str> copy_generic_opt_elem
%type <str> copy_generic_opt_arg
%type <str> copy_generic_opt_arg_list
%type <str> copy_generic_opt_arg_list_item
%type <str> CreateStmt
%type <str> OptTemp
%type <str> OptTableElementList
%type <str> OptTypedTableElementList
%type <str> TableElementList
%type <str> TypedTableElementList
%type <str> TableElement
%type <str> TypedTableElement
%type <str> columnDef
%type <str> columnOptions
%type <str> column_compression
%type <str> opt_column_compression
%type <str> ColQualList
%type <str> ColConstraint
%type <str> ColConstraintElem
%type <str> generated_when
%type <str> ConstraintAttr
%type <str> TableLikeClause
%type <str> TableLikeOptionList
%type <str> TableLikeOption
%type <str> TableConstraint
%type <str> ConstraintElem
%type <str> opt_no_inherit
%type <str> opt_column_list
%type <str> columnList
%type <str> columnElem
%type <str> opt_c_include
%type <str> key_match
%type <str> ExclusionConstraintList
%type <str> ExclusionConstraintElem
%type <str> OptWhereClause
%type <str> key_actions
%type <str> key_update
%type <str> key_delete
%type <str> key_action
%type <str> OptInherit
%type <str> OptPartitionSpec
%type <str> PartitionSpec
%type <str> part_params
%type <str> part_elem
%type <str> table_access_method_clause
%type <str> OptWith
%type <str> OnCommitOption
%type <str> OptTableSpace
%type <str> OptConsTableSpace
%type <str> ExistingIndex
%type <str> CreateStatsStmt
%type <str> stats_params
%type <str> stats_param
%type <str> AlterStatsStmt
%type <str> create_as_target
%type <str> opt_with_data
%type <str> CreateMatViewStmt
%type <str> create_mv_target
%type <str> OptNoLog
%type <str> RefreshMatViewStmt
%type <str> CreateSeqStmt
%type <str> AlterSeqStmt
%type <str> OptSeqOptList
%type <str> OptParenthesizedSeqOptList
%type <str> SeqOptList
%type <str> SeqOptElem
%type <str> opt_by
%type <str> NumericOnly
%type <str> NumericOnly_list
%type <str> CreatePLangStmt
%type <str> opt_trusted
%type <str> handler_name
%type <str> opt_inline_handler
%type <str> validator_clause
%type <str> opt_validator
%type <str> opt_procedural
%type <str> CreateTableSpaceStmt
%type <str> OptTableSpaceOwner
%type <str> DropTableSpaceStmt
%type <str> CreateExtensionStmt
%type <str> create_extension_opt_list
%type <str> create_extension_opt_item
%type <str> AlterExtensionStmt
%type <str> alter_extension_opt_list
%type <str> alter_extension_opt_item
%type <str> AlterExtensionContentsStmt
%type <str> CreateFdwStmt
%type <str> fdw_option
%type <str> fdw_options
%type <str> opt_fdw_options
%type <str> AlterFdwStmt
%type <str> create_generic_options
%type <str> generic_option_list
%type <str> alter_generic_options
%type <str> alter_generic_option_list
%type <str> alter_generic_option_elem
%type <str> generic_option_elem
%type <str> generic_option_name
%type <str> generic_option_arg
%type <str> CreateForeignServerStmt
%type <str> opt_type
%type <str> foreign_server_version
%type <str> opt_foreign_server_version
%type <str> AlterForeignServerStmt
%type <str> CreateForeignTableStmt
%type <str> ImportForeignSchemaStmt
%type <str> import_qualification_type
%type <str> import_qualification
%type <str> CreateUserMappingStmt
%type <str> auth_ident
%type <str> DropUserMappingStmt
%type <str> AlterUserMappingStmt
%type <str> CreatePolicyStmt
%type <str> AlterPolicyStmt
%type <str> RowSecurityOptionalExpr
%type <str> RowSecurityOptionalWithCheck
%type <str> RowSecurityDefaultToRole
%type <str> RowSecurityOptionalToRole
%type <str> RowSecurityDefaultPermissive
%type <str> RowSecurityDefaultForCmd
%type <str> row_security_cmd
%type <str> CreateAmStmt
%type <str> am_type
%type <str> CreateTrigStmt
%type <str> TriggerActionTime
%type <str> TriggerEvents
%type <str> TriggerOneEvent
%type <str> TriggerReferencing
%type <str> TriggerTransitions
%type <str> TriggerTransition
%type <str> TransitionOldOrNew
%type <str> TransitionRowOrTable
%type <str> TransitionRelName
%type <str> TriggerForSpec
%type <str> TriggerForOptEach
%type <str> TriggerForType
%type <str> TriggerWhen
%type <str> FUNCTION_or_PROCEDURE
%type <str> TriggerFuncArgs
%type <str> TriggerFuncArg
%type <str> OptConstrFromTable
%type <str> ConstraintAttributeSpec
%type <str> ConstraintAttributeElem
%type <str> CreateEventTrigStmt
%type <str> event_trigger_when_list
%type <str> event_trigger_when_item
%type <str> event_trigger_value_list
%type <str> AlterEventTrigStmt
%type <str> enable_trigger
%type <str> CreateAssertionStmt
%type <str> DefineStmt
%type <str> definition
%type <str> def_list
%type <str> def_elem
%type <str> def_arg
%type <str> old_aggr_definition
%type <str> old_aggr_list
%type <str> old_aggr_elem
%type <str> opt_enum_val_list
%type <str> enum_val_list
%type <str> AlterEnumStmt
%type <str> opt_if_not_exists
%type <str> CreateOpClassStmt
%type <str> opclass_item_list
%type <str> opclass_item
%type <str> opt_default
%type <str> opt_opfamily
%type <str> opclass_purpose
%type <str> opt_recheck
%type <str> CreateOpFamilyStmt
%type <str> AlterOpFamilyStmt
%type <str> opclass_drop_list
%type <str> opclass_drop
%type <str> DropOpClassStmt
%type <str> DropOpFamilyStmt
%type <str> DropOwnedStmt
%type <str> ReassignOwnedStmt
%type <str> DropStmt
%type <str> object_type_any_name
%type <str> object_type_name
%type <str> drop_type_name
%type <str> object_type_name_on_any_name
%type <str> any_name_list
%type <str> any_name
%type <str> attrs
%type <str> type_name_list
%type <str> TruncateStmt
%type <str> opt_restart_seqs
%type <str> CommentStmt
%type <str> comment_text
%type <str> SecLabelStmt
%type <str> opt_provider
%type <str> security_label
%type <str> FetchStmt
%type <str> fetch_args
%type <str> from_in
%type <str> opt_from_in
%type <str> GrantStmt
%type <str> RevokeStmt
%type <str> privileges
%type <str> privilege_list
%type <str> privilege
%type <str> privilege_target
%type <str> grantee_list
%type <str> grantee
%type <str> opt_grant_grant_option
%type <str> GrantRoleStmt
%type <str> RevokeRoleStmt
%type <str> opt_grant_admin_option
%type <str> opt_granted_by
%type <str> AlterDefaultPrivilegesStmt
%type <str> DefACLOptionList
%type <str> DefACLOption
%type <str> DefACLAction
%type <str> defacl_privilege_target
%type <str> IndexStmt
%type <str> opt_unique
%type <str> opt_concurrently
%type <str> opt_index_name
%type <str> access_method_clause
%type <str> index_params
%type <str> index_elem_options
%type <str> index_elem
%type <str> opt_include
%type <str> index_including_params
%type <str> opt_collate
%type <str> opt_class
%type <str> opt_asc_desc
%type <str> opt_nulls_order
%type <str> CreateFunctionStmt
%type <str> opt_or_replace
%type <str> func_args
%type <str> func_args_list
%type <str> function_with_argtypes_list
%type <str> function_with_argtypes
%type <str> func_args_with_defaults
%type <str> func_args_with_defaults_list
%type <str> func_arg
%type <str> arg_class
%type <str> param_name
%type <str> func_return
%type <str> func_type
%type <str> func_arg_with_default
%type <str> aggr_arg
%type <str> aggr_args
%type <str> aggr_args_list
%type <str> aggregate_with_argtypes
%type <str> aggregate_with_argtypes_list
%type <str> opt_createfunc_opt_list
%type <str> createfunc_opt_list
%type <str> common_func_opt_item
%type <str> createfunc_opt_item
%type <str> func_as
%type <str> ReturnStmt
%type <str> opt_routine_body
%type <str> routine_body_stmt_list
%type <str> routine_body_stmt
%type <str> transform_type_list
%type <str> opt_definition
%type <str> table_func_column
%type <str> table_func_column_list
%type <str> AlterFunctionStmt
%type <str> alterfunc_opt_list
%type <str> opt_restrict
%type <str> RemoveFuncStmt
%type <str> RemoveAggrStmt
%type <str> RemoveOperStmt
%type <str> oper_argtypes
%type <str> any_operator
%type <str> operator_with_argtypes_list
%type <str> operator_with_argtypes
%type <str> DoStmt
%type <str> dostmt_opt_list
%type <str> dostmt_opt_item
%type <str> CreateCastStmt
%type <str> cast_context
%type <str> DropCastStmt
%type <str> opt_if_exists
%type <str> CreateTransformStmt
%type <str> transform_element_list
%type <str> DropTransformStmt
%type <str> ReindexStmt
%type <str> reindex_target_type
%type <str> reindex_target_multitable
%type <str> AlterTblSpcStmt
%type <str> RenameStmt
%type <str> opt_column
%type <str> opt_set_data
%type <str> AlterObjectDependsStmt
%type <str> opt_no
%type <str> AlterObjectSchemaStmt
%type <str> AlterOperatorStmt
%type <str> operator_def_list
%type <str> operator_def_elem
%type <str> operator_def_arg
%type <str> AlterTypeStmt
%type <str> AlterOwnerStmt
%type <str> CreatePublicationStmt
%type <str> opt_publication_for_tables
%type <str> publication_for_tables
%type <str> AlterPublicationStmt
%type <str> CreateSubscriptionStmt
%type <str> AlterSubscriptionStmt
%type <str> DropSubscriptionStmt
%type <str> RuleStmt
%type <str> RuleActionList
%type <str> RuleActionMulti
%type <str> RuleActionStmt
%type <str> RuleActionStmtOrEmpty
%type <str> event
%type <str> opt_instead
%type <str> NotifyStmt
%type <str> notify_payload
%type <str> ListenStmt
%type <str> UnlistenStmt
%type <str> TransactionStmt
%type <str> TransactionStmtLegacy
%type <str> opt_transaction
%type <str> transaction_mode_item
%type <str> transaction_mode_list
%type <str> transaction_mode_list_or_empty
%type <str> opt_transaction_chain
%type <str> ViewStmt
%type <str> opt_check_option
%type <str> LoadStmt
%type <str> CreatedbStmt
%type <str> createdb_opt_list
%type <str> createdb_opt_items
%type <str> createdb_opt_item
%type <str> createdb_opt_name
%type <str> opt_equal
%type <str> AlterDatabaseStmt
%type <str> AlterDatabaseSetStmt
%type <str> DropdbStmt
%type <str> drop_option_list
%type <str> drop_option
%type <str> AlterCollationStmt
%type <str> AlterSystemStmt
%type <str> CreateDomainStmt
%type <str> AlterDomainStmt
%type <str> opt_as
%type <str> AlterTSDictionaryStmt
%type <str> AlterTSConfigurationStmt
%type <str> any_with
%type <str> CreateConversionStmt
%type <str> ClusterStmt
%type <str> cluster_index_specification
%type <str> VacuumStmt
%type <str> AnalyzeStmt
%type <str> utility_option_list
%type <str> analyze_keyword
%type <str> utility_option_elem
%type <str> utility_option_name
%type <str> utility_option_arg
%type <str> opt_analyze
%type <str> opt_verbose
%type <str> opt_full
%type <str> opt_freeze
%type <str> opt_name_list
%type <str> vacuum_relation
%type <str> vacuum_relation_list
%type <str> opt_vacuum_relation_list
%type <str> ExplainStmt
%type <str> ExplainableStmt
%type <prep> PrepareStmt
%type <str> prep_type_clause
%type <str> PreparableStmt
%type <exec> ExecuteStmt
%type <str> execute_param_clause
%type <str> InsertStmt
%type <str> insert_target
%type <str> insert_rest
%type <str> override_kind
%type <str> insert_column_list
%type <str> insert_column_item
%type <str> opt_on_conflict
%type <str> opt_conf_expr
%type <str> returning_clause
%type <str> DeleteStmt
%type <str> using_clause
%type <str> LockStmt
%type <str> opt_lock
%type <str> lock_type
%type <str> opt_nowait
%type <str> opt_nowait_or_skip
%type <str> UpdateStmt
%type <str> set_clause_list
%type <str> set_clause
%type <str> set_target
%type <str> set_target_list
%type <str> DeclareCursorStmt
%type <str> cursor_name
%type <str> cursor_options
%type <str> opt_hold
%type <str> SelectStmt
%type <str> select_with_parens
%type <str> select_no_parens
%type <str> select_clause
%type <str> simple_select
%type <str> with_clause
%type <str> cte_list
%type <str> common_table_expr
%type <str> opt_materialized
%type <str> opt_search_clause
%type <str> opt_cycle_clause
%type <str> opt_with_clause
%type <str> into_clause
%type <str> OptTempTableName
%type <str> opt_table
%type <str> set_quantifier
%type <str> distinct_clause
%type <str> opt_all_clause
%type <str> opt_sort_clause
%type <str> sort_clause
%type <str> sortby_list
%type <str> sortby
%type <str> select_limit
%type <str> opt_select_limit
%type <str> limit_clause
%type <str> offset_clause
%type <str> select_limit_value
%type <str> select_offset_value
%type <str> select_fetch_first_value
%type <str> I_or_F_const
%type <str> row_or_rows
%type <str> first_or_next
%type <str> group_clause
%type <str> group_by_list
%type <str> group_by_item
%type <str> empty_grouping_set
%type <str> rollup_clause
%type <str> cube_clause
%type <str> grouping_sets_clause
%type <str> having_clause
%type <str> for_locking_clause
%type <str> opt_for_locking_clause
%type <str> for_locking_items
%type <str> for_locking_item
%type <str> for_locking_strength
%type <str> locked_rels_list
%type <str> values_clause
%type <str> from_clause
%type <str> from_list
%type <str> table_ref
%type <str> joined_table
%type <str> alias_clause
%type <str> opt_alias_clause
%type <str> opt_alias_clause_for_join_using
%type <str> func_alias_clause
%type <str> join_type
%type <str> opt_outer
%type <str> join_qual
%type <str> relation_expr
%type <str> relation_expr_list
%type <str> relation_expr_opt_alias
%type <str> tablesample_clause
%type <str> opt_repeatable_clause
%type <str> func_table
%type <str> rowsfrom_item
%type <str> rowsfrom_list
%type <str> opt_col_def_list
%type <str> opt_ordinality
%type <str> where_clause
%type <str> where_or_current_clause
%type <str> OptTableFuncElementList
%type <str> TableFuncElementList
%type <str> TableFuncElement
%type <str> xmltable
%type <str> xmltable_column_list
%type <str> xmltable_column_el
%type <str> xmltable_column_option_list
%type <str> xmltable_column_option_el
%type <str> xml_namespace_list
%type <str> xml_namespace_el
%type <str> Typename
%type <index> opt_array_bounds
%type <str> SimpleTypename
%type <str> ConstTypename
%type <str> GenericType
%type <str> opt_type_modifiers
%type <str> Numeric
%type <str> opt_float
%type <str> Bit
%type <str> ConstBit
%type <str> BitWithLength
%type <str> BitWithoutLength
%type <str> Character
%type <str> ConstCharacter
%type <str> CharacterWithLength
%type <str> CharacterWithoutLength
%type <str> character
%type <str> opt_varying
%type <str> ConstDatetime
%type <str> ConstInterval
%type <str> opt_timezone
%type <str> opt_interval
%type <str> interval_second
%type <str> a_expr
%type <str> b_expr
%type <str> c_expr
%type <str> func_application
%type <str> func_expr
%type <str> func_expr_windowless
%type <str> func_expr_common_subexpr
%type <str> xml_root_version
%type <str> opt_xml_root_standalone
%type <str> xml_attributes
%type <str> xml_attribute_list
%type <str> xml_attribute_el
%type <str> document_or_content
%type <str> xml_whitespace_option
%type <str> xmlexists_argument
%type <str> xml_passing_mech
%type <str> within_group_clause
%type <str> filter_clause
%type <str> window_clause
%type <str> window_definition_list
%type <str> window_definition
%type <str> over_clause
%type <str> window_specification
%type <str> opt_existing_window_name
%type <str> opt_partition_clause
%type <str> opt_frame_clause
%type <str> frame_extent
%type <str> frame_bound
%type <str> opt_window_exclusion_clause
%type <str> row
%type <str> explicit_row
%type <str> implicit_row
%type <str> sub_type
%type <str> all_Op
%type <str> MathOp
%type <str> qual_Op
%type <str> qual_all_Op
%type <str> subquery_Op
%type <str> expr_list
%type <str> func_arg_list
%type <str> func_arg_expr
%type <str> func_arg_list_opt
%type <str> type_list
%type <str> array_expr
%type <str> array_expr_list
%type <str> extract_list
%type <str> extract_arg
%type <str> unicode_normal_form
%type <str> overlay_list
%type <str> position_list
%type <str> substr_list
%type <str> trim_list
%type <str> in_expr
%type <str> case_expr
%type <str> when_clause_list
%type <str> when_clause
%type <str> case_default
%type <str> case_arg
%type <str> columnref
%type <str> indirection_el
%type <str> opt_slice_bound
%type <str> indirection
%type <str> opt_indirection
%type <str> opt_asymmetric
%type <str> opt_target_list
%type <str> target_list
%type <str> target_el
%type <str> qualified_name_list
%type <str> qualified_name
%type <str> name_list
%type <str> name
%type <str> attr_name
%type <str> file_name
%type <str> func_name
%type <str> AexprConst
%type <str> Iconst
%type <str> SignedIconst
%type <str> RoleId
%type <str> RoleSpec
%type <str> role_list
%type <str> NonReservedWord
%type <str> BareColLabel
%type <str> unreserved_keyword
%type <str> col_name_keyword
%type <str> type_func_name_keyword
%type <str> reserved_keyword
%type <str> bare_label_keyword
/* ecpgtype */
/* src/interfaces/ecpg/preproc/ecpg.type */
%type <str> ECPGAllocateDescr
%type <str> ECPGCKeywords
%type <str> ECPGColId
%type <str> ECPGColLabel
%type <str> ECPGColLabelCommon
%type <str> ECPGConnect
%type <str> ECPGCursorStmt
%type <str> ECPGDeallocateDescr
%type <str> ECPGDeclaration
%type <str> ECPGDeclare
%type <str> ECPGDeclareStmt
%type <str> ECPGDisconnect
%type <str> ECPGExecuteImmediateStmt
%type <str> ECPGFree
%type <str> ECPGGetDescHeaderItem
%type <str> ECPGGetDescItem
%type <str> ECPGGetDescriptorHeader
%type <str> ECPGKeywords
%type <str> ECPGKeywords_rest
%type <str> ECPGKeywords_vanames
%type <str> ECPGOpen
%type <str> ECPGSetAutocommit
%type <str> ECPGSetConnection
%type <str> ECPGSetDescHeaderItem
%type <str> ECPGSetDescItem
%type <str> ECPGSetDescriptorHeader
%type <str> ECPGTypeName
%type <str> ECPGTypedef
%type <str> ECPGVar
%type <str> ECPGVarDeclaration
%type <str> ECPGWhenever
%type <str> ECPGunreserved_interval
%type <str> UsingConst
%type <str> UsingValue
%type <str> all_unreserved_keyword
%type <str> c_anything
%type <str> c_args
%type <str> c_list
%type <str> c_stuff
%type <str> c_stuff_item
%type <str> c_term
%type <str> c_thing
%type <str> char_variable
%type <str> char_civar
%type <str> civar
%type <str> civarind
%type <str> ColId
%type <str> ColLabel
%type <str> connect_options
%type <str> connection_object
%type <str> connection_target
%type <str> coutputvariable
%type <str> cvariable
%type <str> db_prefix
%type <str> CreateAsStmt
%type <str> DeallocateStmt
%type <str> dis_name
%type <str> ecpg_bconst
%type <str> ecpg_fconst
%type <str> ecpg_ident
%type <str> ecpg_interval
%type <str> ecpg_into
%type <str> ecpg_fetch_into
%type <str> ecpg_param
%type <str> ecpg_sconst
%type <str> ecpg_using
%type <str> ecpg_xconst
%type <str> enum_definition
%type <str> enum_type
%type <str> execstring
%type <str> execute_rest
%type <str> indicator
%type <str> into_descriptor
%type <str> into_sqlda
%type <str> Iresult
%type <str> on_off
%type <str> opt_bit_field
%type <str> opt_connection_name
%type <str> opt_database_name
%type <str> opt_ecpg_into
%type <str> opt_ecpg_fetch_into
%type <str> opt_ecpg_using
%type <str> opt_initializer
%type <str> opt_options
%type <str> opt_output
%type <str> opt_pointer
%type <str> opt_port
%type <str> opt_reference
%type <str> opt_scale
%type <str> opt_server
%type <str> opt_user
%type <str> opt_opt_value
%type <str> ora_user
%type <str> precision
%type <str> prepared_name
%type <str> quoted_ident_stringvar
%type <str> s_struct_union
%type <str> server
%type <str> server_name
%type <str> single_vt_declaration
%type <str> storage_clause
%type <str> storage_declaration
%type <str> storage_modifier
%type <str> struct_union_type
%type <str> struct_union_type_with_symbol
%type <str> symbol
%type <str> type_declaration
%type <str> type_function_name
%type <str> user_name
%type <str> using_descriptor
%type <str> var_declaration
%type <str> var_type_declarations
%type <str> variable
%type <str> variable_declarations
%type <str> variable_list
%type <str> vt_declarations

%type <str> Op
%type <str> IntConstVar
%type <str> AllConstVar
%type <str> CSTRING
%type <str> CPP_LINE
%type <str> CVARIABLE
%type <str> BCONST
%type <str> SCONST
%type <str> XCONST
%type <str> IDENT

%type  <struct_union> s_struct_union_symbol

%type  <descriptor> ECPGGetDescriptor
%type  <descriptor> ECPGSetDescriptor

%type  <type_enum> simple_type
%type  <type_enum> signed_type
%type  <type_enum> unsigned_type

%type  <dtype_enum> descriptor_item
%type  <dtype_enum> desc_header_item

%type  <type>   var_type

%type  <action> action

%type  <describe> ECPGDescribe
/* orig_tokens */
 %token IDENT UIDENT FCONST SCONST USCONST BCONST XCONST Op
 %token ICONST PARAM
 %token TYPECAST DOT_DOT COLON_EQUALS EQUALS_GREATER
 %token LESS_EQUALS GREATER_EQUALS NOT_EQUALS









 %token ABORT_P ABSOLUTE_P ACCESS ACTION ADD_P ADMIN AFTER
 AGGREGATE ALL ALSO ALTER ALWAYS ANALYSE ANALYZE AND ANY ARRAY AS ASC
 ASENSITIVE ASSERTION ASSIGNMENT ASYMMETRIC ATOMIC AT ATTACH ATTRIBUTE AUTHORIZATION

 BACKWARD BEFORE BEGIN_P BETWEEN BIGINT BINARY BIT
 BOOLEAN_P BOTH BREADTH BY

 CACHE CALL CALLED CASCADE CASCADED CASE CAST CATALOG_P CHAIN CHAR_P
 CHARACTER CHARACTERISTICS CHECK CHECKPOINT CLASS CLOSE
 CLUSTER COALESCE COLLATE COLLATION COLUMN COLUMNS COMMENT COMMENTS COMMIT
 COMMITTED COMPRESSION CONCURRENTLY CONFIGURATION CONFLICT
 CONNECTION CONSTRAINT CONSTRAINTS CONTENT_P CONTINUE_P CONVERSION_P COPY
 COST CREATE CROSS CSV CUBE CURRENT_P
 CURRENT_CATALOG CURRENT_DATE CURRENT_ROLE CURRENT_SCHEMA
 CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER CURSOR CYCLE

 DATA_P DATABASE DAY_P DEALLOCATE DEC DECIMAL_P DECLARE DEFAULT DEFAULTS
 DEFERRABLE DEFERRED DEFINER DELETE_P DELIMITER DELIMITERS DEPENDS DEPTH DESC
 DETACH DICTIONARY DISABLE_P DISCARD DISTINCT DO DOCUMENT_P DOMAIN_P
 DOUBLE_P DROP

 EACH ELSE ENABLE_P ENCODING ENCRYPTED END_P ENUM_P ESCAPE EVENT EXCEPT
 EXCLUDE EXCLUDING EXCLUSIVE EXECUTE EXISTS EXPLAIN EXPRESSION
 EXTENSION EXTERNAL EXTRACT

 FALSE_P FAMILY FETCH FILTER FINALIZE FIRST_P FLOAT_P FOLLOWING FOR
 FORCE FOREIGN FORWARD FREEZE FROM FULL FUNCTION FUNCTIONS

 GENERATED GLOBAL GRANT GRANTED GREATEST GROUP_P GROUPING GROUPS

 HANDLER HAVING HEADER_P HOLD HOUR_P

 IDENTITY_P IF_P ILIKE IMMEDIATE IMMUTABLE IMPLICIT_P IMPORT_P IN_P INCLUDE
 INCLUDING INCREMENT INDEX INDEXES INHERIT INHERITS INITIALLY INLINE_P
 INNER_P INOUT INPUT_P INSENSITIVE INSERT INSTEAD INT_P INTEGER
 INTERSECT INTERVAL INTO INVOKER IS ISNULL ISOLATION

 JOIN

 KEY

 LABEL LANGUAGE LARGE_P LAST_P LATERAL_P
 LEADING LEAKPROOF LEAST LEFT LEVEL LIKE LIMIT LISTEN LOAD LOCAL
 LOCALTIME LOCALTIMESTAMP LOCATION LOCK_P LOCKED LOGGED

 MAPPING MATCH MATERIALIZED MAXVALUE METHOD MINUTE_P MINVALUE MODE MONTH_P MOVE

 NAME_P NAMES NATIONAL NATURAL NCHAR NEW NEXT NFC NFD NFKC NFKD NO NONE
 NORMALIZE NORMALIZED
 NOT NOTHING NOTIFY NOTNULL NOWAIT NULL_P NULLIF
 NULLS_P NUMERIC

 OBJECT_P OF OFF OFFSET OIDS OLD ON ONLY OPERATOR OPTION OPTIONS OR
 ORDER ORDINALITY OTHERS OUT_P OUTER_P
 OVER OVERLAPS OVERLAY OVERRIDING OWNED OWNER

 PARALLEL PARSER PARTIAL PARTITION PASSING PASSWORD PLACING PLANS POLICY
 POSITION PRECEDING PRECISION PRESERVE PREPARE PREPARED PRIMARY
 PRIOR PRIVILEGES PROCEDURAL PROCEDURE PROCEDURES PROGRAM PUBLICATION

 QUOTE

 RANGE READ REAL REASSIGN RECHECK RECURSIVE REF_P REFERENCES REFERENCING
 REFRESH REINDEX RELATIVE_P RELEASE RENAME REPEATABLE REPLACE REPLICA
 RESET RESTART RESTRICT RETURN RETURNING RETURNS REVOKE RIGHT ROLE ROLLBACK ROLLUP
 ROUTINE ROUTINES ROW ROWS RULE

 SAVEPOINT SCHEMA SCHEMAS SCROLL SEARCH SECOND_P SECURITY SELECT SEQUENCE SEQUENCES
 SERIALIZABLE SERVER SESSION SESSION_USER SET SETS SETOF SHARE SHOW
 SIMILAR SIMPLE SKIP SMALLINT SNAPSHOT SOME SQL_P STABLE STANDALONE_P
 START STATEMENT STATISTICS STDIN STDOUT STORAGE STORED STRICT_P STRIP_P
 SUBSCRIPTION SUBSTRING SUPPORT SYMMETRIC SYSID SYSTEM_P

 TABLE TABLES TABLESAMPLE TABLESPACE TEMP TEMPLATE TEMPORARY TEXT_P THEN
 TIES TIME TIMESTAMP TO TRAILING TRANSACTION TRANSFORM
 TREAT TRIGGER TRIM TRUE_P
 TRUNCATE TRUSTED TYPE_P TYPES_P

 UESCAPE UNBOUNDED UNCOMMITTED UNENCRYPTED UNION UNIQUE UNKNOWN
 UNLISTEN UNLOGGED UNTIL UPDATE USER USING

 VACUUM VALID VALIDATE VALIDATOR VALUE_P VALUES VARCHAR VARIADIC VARYING
 VERBOSE VERSION_P VIEW VIEWS VOLATILE

 WHEN WHERE WHITESPACE_P WINDOW WITH WITHIN WITHOUT WORK WRAPPER WRITE

 XML_P XMLATTRIBUTES XMLCONCAT XMLELEMENT XMLEXISTS XMLFOREST XMLNAMESPACES
 XMLPARSE XMLPI XMLROOT XMLSERIALIZE XMLTABLE

 YEAR_P YES_P

 ZONE











 %token NOT_LA NULLS_LA WITH_LA








 %token MODE_TYPE_NAME
 %token MODE_PLPGSQL_EXPR
 %token MODE_PLPGSQL_ASSIGN1
 %token MODE_PLPGSQL_ASSIGN2
 %token MODE_PLPGSQL_ASSIGN3



 %nonassoc SET
 %left UNION EXCEPT
 %left INTERSECT
 %left OR
 %left AND
 %right NOT
 %nonassoc IS ISNULL NOTNULL
 %nonassoc '<' '>' '=' LESS_EQUALS GREATER_EQUALS NOT_EQUALS
 %nonassoc BETWEEN IN_P LIKE ILIKE SIMILAR NOT_LA
 %nonassoc ESCAPE

























 %nonassoc UNBOUNDED
 %nonassoc IDENT
%nonassoc CSTRING PARTITION RANGE ROWS GROUPS PRECEDING FOLLOWING CUBE ROLLUP
 %left Op OPERATOR
 %left '+' '-'
 %left '*' '/' '%'
 %left '^'

 %left AT
 %left COLLATE
 %right UMINUS
 %left '[' ']'
 %left '(' ')'
 %left TYPECAST
 %left '.'







 %left JOIN CROSS LEFT FULL RIGHT INNER_P NATURAL

%%
prog: statements;
/* rules */
 toplevel_stmt:
 stmt
 { 
 $$ = $1;
}
|  TransactionStmtLegacy
	{
		fprintf(base_yyout, "{ ECPGtrans(__LINE__, %s, \"%s\");", connection ? connection : "NULL", $1);
		whenever_action(2);
		free($1);
	}
;


 stmt:
 AlterEventTrigStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterCollationStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterDatabaseStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterDatabaseSetStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterDefaultPrivilegesStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterDomainStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterEnumStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterExtensionStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterExtensionContentsStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterFdwStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterForeignServerStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterFunctionStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterGroupStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterObjectDependsStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterObjectSchemaStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterOwnerStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterOperatorStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterTypeStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterPolicyStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterSeqStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterSystemStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterTableStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterTblSpcStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterCompositeTypeStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterPublicationStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterRoleSetStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterRoleStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterSubscriptionStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterStatsStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterTSConfigurationStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterTSDictionaryStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterUserMappingStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AnalyzeStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CallStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CheckPointStmt
 { output_statement($1, 0, ECPGst_normal); }
|  ClosePortalStmt
	{
		if (INFORMIX_MODE)
		{
			if (pg_strcasecmp($1+strlen("close "), "database") == 0)
			{
				if (connection)
					mmerror(PARSE_ERROR, ET_ERROR, "AT option not allowed in CLOSE DATABASE statement");

				fprintf(base_yyout, "{ ECPGdisconnect(__LINE__, \"CURRENT\");");
				whenever_action(2);
				free($1);
				break;
			}
		}

		output_statement($1, 0, ECPGst_normal);
	}
|  ClusterStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CommentStmt
 { output_statement($1, 0, ECPGst_normal); }
|  ConstraintsSetStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CopyStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateAmStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateAsStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateAssertionStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateCastStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateConversionStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateDomainStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateExtensionStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateFdwStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateForeignServerStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateForeignTableStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateFunctionStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateGroupStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateMatViewStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateOpClassStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateOpFamilyStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreatePublicationStmt
 { output_statement($1, 0, ECPGst_normal); }
|  AlterOpFamilyStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreatePolicyStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreatePLangStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateSchemaStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateSeqStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateSubscriptionStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateStatsStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateTableSpaceStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateTransformStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateTrigStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateEventTrigStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateRoleStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateUserStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreateUserMappingStmt
 { output_statement($1, 0, ECPGst_normal); }
|  CreatedbStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DeallocateStmt
	{
		output_deallocate_prepare_statement($1);
	}
|  DeclareCursorStmt
	{ output_simple_statement($1, (strncmp($1, "ECPGset_var", strlen("ECPGset_var")) == 0) ? 4 : 0); }
|  DefineStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DeleteStmt
	{ output_statement($1, 1, ECPGst_prepnormal); }
|  DiscardStmt
	{ output_statement($1, 1, ECPGst_normal); }
|  DoStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DropCastStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DropOpClassStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DropOpFamilyStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DropOwnedStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DropStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DropSubscriptionStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DropTableSpaceStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DropTransformStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DropRoleStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DropUserMappingStmt
 { output_statement($1, 0, ECPGst_normal); }
|  DropdbStmt
 { output_statement($1, 0, ECPGst_normal); }
|  ExecuteStmt
	{
		check_declared_list($1.name);
		if ($1.type == NULL || strlen($1.type) == 0)
			output_statement($1.name, 1, ECPGst_execute);
		else
		{
			if ($1.name[0] != '"')
				/* case of char_variable */
				add_variable_to_tail(&argsinsert, find_variable($1.name), &no_indicator);
			else
			{
				/* case of ecpg_ident or CSTRING */
				char *length = mm_alloc(sizeof(int) * CHAR_BIT * 10 / 3);
				char *str = mm_strdup($1.name + 1);

				/* It must be cut off double quotation because new_variable() double-quotes. */
				str[strlen(str) - 1] = '\0';
				sprintf(length, "%zu", strlen(str));
				add_variable_to_tail(&argsinsert, new_variable(str, ECPGmake_simple_type(ECPGt_const, length, 0), 0), &no_indicator);
			}
			output_statement(cat_str(3, mm_strdup("execute"), mm_strdup("$0"), $1.type), 0, ECPGst_exec_with_exprlist);
		}
	}
|  ExplainStmt
 { output_statement($1, 0, ECPGst_normal); }
|  FetchStmt
	{ output_statement($1, 1, ECPGst_normal); }
|  GrantStmt
 { output_statement($1, 0, ECPGst_normal); }
|  GrantRoleStmt
 { output_statement($1, 0, ECPGst_normal); }
|  ImportForeignSchemaStmt
 { output_statement($1, 0, ECPGst_normal); }
|  IndexStmt
 { output_statement($1, 0, ECPGst_normal); }
|  InsertStmt
	{ output_statement($1, 1, ECPGst_prepnormal); }
|  ListenStmt
 { output_statement($1, 0, ECPGst_normal); }
|  RefreshMatViewStmt
 { output_statement($1, 0, ECPGst_normal); }
|  LoadStmt
 { output_statement($1, 0, ECPGst_normal); }
|  LockStmt
 { output_statement($1, 0, ECPGst_normal); }
|  NotifyStmt
 { output_statement($1, 0, ECPGst_normal); }
|  PrepareStmt
	{
		check_declared_list($1.name);
		if ($1.type == NULL)
			output_prepare_statement($1.name, $1.stmt);
		else if (strlen($1.type) == 0)
		{
			char *stmt = cat_str(3, mm_strdup("\""), $1.stmt, mm_strdup("\""));
			output_prepare_statement($1.name, stmt);
		}
		else
		{
			if ($1.name[0] != '"')
				/* case of char_variable */
				add_variable_to_tail(&argsinsert, find_variable($1.name), &no_indicator);
			else
			{
				char *length = mm_alloc(sizeof(int) * CHAR_BIT * 10 / 3);
				char *str = mm_strdup($1.name + 1);

				/* It must be cut off double quotation because new_variable() double-quotes. */
				str[strlen(str) - 1] = '\0';
				sprintf(length, "%zu", strlen(str));
				add_variable_to_tail(&argsinsert, new_variable(str, ECPGmake_simple_type(ECPGt_const, length, 0), 0), &no_indicator);
			}
			output_statement(cat_str(5, mm_strdup("prepare"), mm_strdup("$0"), $1.type, mm_strdup("as"), $1.stmt), 0, ECPGst_prepare);
		}
	}
|  ReassignOwnedStmt
 { output_statement($1, 0, ECPGst_normal); }
|  ReindexStmt
 { output_statement($1, 0, ECPGst_normal); }
|  RemoveAggrStmt
 { output_statement($1, 0, ECPGst_normal); }
|  RemoveFuncStmt
 { output_statement($1, 0, ECPGst_normal); }
|  RemoveOperStmt
 { output_statement($1, 0, ECPGst_normal); }
|  RenameStmt
 { output_statement($1, 0, ECPGst_normal); }
|  RevokeStmt
 { output_statement($1, 0, ECPGst_normal); }
|  RevokeRoleStmt
 { output_statement($1, 0, ECPGst_normal); }
|  RuleStmt
 { output_statement($1, 0, ECPGst_normal); }
|  SecLabelStmt
 { output_statement($1, 0, ECPGst_normal); }
|  SelectStmt
	{ output_statement($1, 1, ECPGst_prepnormal); }
|  TransactionStmt
	{
		fprintf(base_yyout, "{ ECPGtrans(__LINE__, %s, \"%s\");", connection ? connection : "NULL", $1);
		whenever_action(2);
		free($1);
	}
|  TruncateStmt
 { output_statement($1, 0, ECPGst_normal); }
|  UnlistenStmt
 { output_statement($1, 0, ECPGst_normal); }
|  UpdateStmt
	{ output_statement($1, 1, ECPGst_prepnormal); }
|  VacuumStmt
 { output_statement($1, 0, ECPGst_normal); }
|  VariableResetStmt
 { output_statement($1, 0, ECPGst_normal); }
|  VariableSetStmt
 { output_statement($1, 0, ECPGst_normal); }
|  VariableShowStmt
 { output_statement($1, 0, ECPGst_normal); }
|  ViewStmt
 { output_statement($1, 0, ECPGst_normal); }
	| ECPGAllocateDescr
	{
		fprintf(base_yyout,"ECPGallocate_desc(__LINE__, %s);",$1);
		whenever_action(0);
		free($1);
	}
	| ECPGConnect
	{
		if (connection)
			mmerror(PARSE_ERROR, ET_ERROR, "AT option not allowed in CONNECT statement");

		fprintf(base_yyout, "{ ECPGconnect(__LINE__, %d, %s, %d); ", compat, $1, autocommit);
		reset_variables();
		whenever_action(2);
		free($1);
	}
	| ECPGDeclareStmt
	{
		output_simple_statement($1, 0);
	}
	| ECPGCursorStmt
	{
		 output_simple_statement($1, (strncmp($1, "ECPGset_var", strlen("ECPGset_var")) == 0) ? 4 : 0);
	}
	| ECPGDeallocateDescr
	{
		fprintf(base_yyout,"ECPGdeallocate_desc(__LINE__, %s);",$1);
		whenever_action(0);
		free($1);
	}
	| ECPGDeclare
	{
		output_simple_statement($1, 0);
	}
	| ECPGDescribe
	{
		check_declared_list($1.stmt_name);

		fprintf(base_yyout, "{ ECPGdescribe(__LINE__, %d, %d, %s, %s,", compat, $1.input, connection ? connection : "NULL", $1.stmt_name);
		dump_variables(argsresult, 1);
		fputs("ECPGt_EORT);", base_yyout);
		fprintf(base_yyout, "}");
		output_line_number();

		free($1.stmt_name);
	}
	| ECPGDisconnect
	{
		if (connection)
			mmerror(PARSE_ERROR, ET_ERROR, "AT option not allowed in DISCONNECT statement");

		fprintf(base_yyout, "{ ECPGdisconnect(__LINE__, %s);",
				$1 ? $1 : "\"CURRENT\"");
		whenever_action(2);
		free($1);
	}
	| ECPGExecuteImmediateStmt	{ output_statement($1, 0, ECPGst_exec_immediate); }
	| ECPGFree
	{
		const char *con = connection ? connection : "NULL";

		if (strcmp($1, "all") == 0)
			fprintf(base_yyout, "{ ECPGdeallocate_all(__LINE__, %d, %s);", compat, con);
		else if ($1[0] == ':')
			fprintf(base_yyout, "{ ECPGdeallocate(__LINE__, %d, %s, %s);", compat, con, $1+1);
		else
			fprintf(base_yyout, "{ ECPGdeallocate(__LINE__, %d, %s, \"%s\");", compat, con, $1);

		whenever_action(2);
		free($1);
	}
	| ECPGGetDescriptor
	{
		lookup_descriptor($1.name, connection);
		output_get_descr($1.name, $1.str);
		free($1.name);
		free($1.str);
	}
	| ECPGGetDescriptorHeader
	{
		lookup_descriptor($1, connection);
		output_get_descr_header($1);
		free($1);
	}
	| ECPGOpen
	{
		struct cursor *ptr;

		if ((ptr = add_additional_variables($1, true)) != NULL)
		{
			connection = ptr->connection ? mm_strdup(ptr->connection) : NULL;
			output_statement(mm_strdup(ptr->command), 0, ECPGst_normal);
			ptr->opened = true;
		}
	}
	| ECPGSetAutocommit
	{
		fprintf(base_yyout, "{ ECPGsetcommit(__LINE__, \"%s\", %s);", $1, connection ? connection : "NULL");
		whenever_action(2);
		free($1);
	}
	| ECPGSetConnection
	{
		if (connection)
			mmerror(PARSE_ERROR, ET_ERROR, "AT option not allowed in SET CONNECTION statement");

		fprintf(base_yyout, "{ ECPGsetconn(__LINE__, %s);", $1);
		whenever_action(2);
		free($1);
	}
	| ECPGSetDescriptor
	{
		lookup_descriptor($1.name, connection);
		output_set_descr($1.name, $1.str);
		free($1.name);
		free($1.str);
	}
	| ECPGSetDescriptorHeader
	{
		lookup_descriptor($1, connection);
		output_set_descr_header($1);
		free($1);
	}
	| ECPGTypedef
	{
		if (connection)
			mmerror(PARSE_ERROR, ET_ERROR, "AT option not allowed in TYPE statement");

		fprintf(base_yyout, "%s", $1);
		free($1);
		output_line_number();
	}
	| ECPGVar
	{
		if (connection)
			mmerror(PARSE_ERROR, ET_ERROR, "AT option not allowed in VAR statement");

		output_simple_statement($1, 0);
	}
	| ECPGWhenever
	{
		if (connection)
			mmerror(PARSE_ERROR, ET_ERROR, "AT option not allowed in WHENEVER statement");

		output_simple_statement($1, 0);
	}
| 
 { $$ = NULL; }
;


 CallStmt:
 CALL func_application
 { 
 $$ = cat_str(2,mm_strdup("call"),$2);
}
;


 CreateRoleStmt:
 CREATE ROLE RoleId opt_with OptRoleList
 { 
 $$ = cat_str(4,mm_strdup("create role"),$3,$4,$5);
}
;


 opt_with:
 WITH
 { 
 $$ = mm_strdup("with");
}
|  WITH_LA
 { 
 $$ = mm_strdup("with");
}
| 
 { 
 $$=EMPTY; }
;


 OptRoleList:
 OptRoleList CreateOptRoleElem
 { 
 $$ = cat_str(2,$1,$2);
}
| 
 { 
 $$=EMPTY; }
;


 AlterOptRoleList:
 AlterOptRoleList AlterOptRoleElem
 { 
 $$ = cat_str(2,$1,$2);
}
| 
 { 
 $$=EMPTY; }
;


 AlterOptRoleElem:
 PASSWORD ecpg_sconst
 { 
 $$ = cat_str(2,mm_strdup("password"),$2);
}
|  PASSWORD NULL_P
 { 
 $$ = mm_strdup("password null");
}
|  ENCRYPTED PASSWORD ecpg_sconst
 { 
 $$ = cat_str(2,mm_strdup("encrypted password"),$3);
}
|  UNENCRYPTED PASSWORD ecpg_sconst
 { 
mmerror(PARSE_ERROR, ET_WARNING, "unsupported feature will be passed to server");
 $$ = cat_str(2,mm_strdup("unencrypted password"),$3);
}
|  INHERIT
 { 
 $$ = mm_strdup("inherit");
}
|  CONNECTION LIMIT SignedIconst
 { 
 $$ = cat_str(2,mm_strdup("connection limit"),$3);
}
|  VALID UNTIL ecpg_sconst
 { 
 $$ = cat_str(2,mm_strdup("valid until"),$3);
}
|  USER role_list
 { 
 $$ = cat_str(2,mm_strdup("user"),$2);
}
|  ecpg_ident
 { 
 $$ = $1;
}
;


 CreateOptRoleElem:
 AlterOptRoleElem
 { 
 $$ = $1;
}
|  SYSID Iconst
 { 
 $$ = cat_str(2,mm_strdup("sysid"),$2);
}
|  ADMIN role_list
 { 
 $$ = cat_str(2,mm_strdup("admin"),$2);
}
|  ROLE role_list
 { 
 $$ = cat_str(2,mm_strdup("role"),$2);
}
|  IN_P ROLE role_list
 { 
 $$ = cat_str(2,mm_strdup("in role"),$3);
}
|  IN_P GROUP_P role_list
 { 
 $$ = cat_str(2,mm_strdup("in group"),$3);
}
;


 CreateUserStmt:
 CREATE USER RoleId opt_with OptRoleList
 { 
 $$ = cat_str(4,mm_strdup("create user"),$3,$4,$5);
}
;


 AlterRoleStmt:
 ALTER ROLE RoleSpec opt_with AlterOptRoleList
 { 
 $$ = cat_str(4,mm_strdup("alter role"),$3,$4,$5);
}
|  ALTER USER RoleSpec opt_with AlterOptRoleList
 { 
 $$ = cat_str(4,mm_strdup("alter user"),$3,$4,$5);
}
;


 opt_in_database:

 { 
 $$=EMPTY; }
|  IN_P DATABASE name
 { 
 $$ = cat_str(2,mm_strdup("in database"),$3);
}
;


 AlterRoleSetStmt:
 ALTER ROLE RoleSpec opt_in_database SetResetClause
 { 
 $$ = cat_str(4,mm_strdup("alter role"),$3,$4,$5);
}
|  ALTER ROLE ALL opt_in_database SetResetClause
 { 
 $$ = cat_str(3,mm_strdup("alter role all"),$4,$5);
}
|  ALTER USER RoleSpec opt_in_database SetResetClause
 { 
 $$ = cat_str(4,mm_strdup("alter user"),$3,$4,$5);
}
|  ALTER USER ALL opt_in_database SetResetClause
 { 
 $$ = cat_str(3,mm_strdup("alter user all"),$4,$5);
}
;


 DropRoleStmt:
 DROP ROLE role_list
 { 
 $$ = cat_str(2,mm_strdup("drop role"),$3);
}
|  DROP ROLE IF_P EXISTS role_list
 { 
 $$ = cat_str(2,mm_strdup("drop role if exists"),$5);
}
|  DROP USER role_list
 { 
 $$ = cat_str(2,mm_strdup("drop user"),$3);
}
|  DROP USER IF_P EXISTS role_list
 { 
 $$ = cat_str(2,mm_strdup("drop user if exists"),$5);
}
|  DROP GROUP_P role_list
 { 
 $$ = cat_str(2,mm_strdup("drop group"),$3);
}
|  DROP GROUP_P IF_P EXISTS role_list
 { 
 $$ = cat_str(2,mm_strdup("drop group if exists"),$5);
}
;


 CreateGroupStmt:
 CREATE GROUP_P RoleId opt_with OptRoleList
 { 
 $$ = cat_str(4,mm_strdup("create group"),$3,$4,$5);
}
;


 AlterGroupStmt:
 ALTER GROUP_P RoleSpec add_drop USER role_list
 { 
 $$ = cat_str(5,mm_strdup("alter group"),$3,$4,mm_strdup("user"),$6);
}
;


 add_drop:
 ADD_P
 { 
 $$ = mm_strdup("add");
}
|  DROP
 { 
 $$ = mm_strdup("drop");
}
;


 CreateSchemaStmt:
 CREATE SCHEMA OptSchemaName AUTHORIZATION RoleSpec OptSchemaEltList
 { 
 $$ = cat_str(5,mm_strdup("create schema"),$3,mm_strdup("authorization"),$5,$6);
}
|  CREATE SCHEMA ColId OptSchemaEltList
 { 
 $$ = cat_str(3,mm_strdup("create schema"),$3,$4);
}
|  CREATE SCHEMA IF_P NOT EXISTS OptSchemaName AUTHORIZATION RoleSpec OptSchemaEltList
 { 
 $$ = cat_str(5,mm_strdup("create schema if not exists"),$6,mm_strdup("authorization"),$8,$9);
}
|  CREATE SCHEMA IF_P NOT EXISTS ColId OptSchemaEltList
 { 
 $$ = cat_str(3,mm_strdup("create schema if not exists"),$6,$7);
}
;


 OptSchemaName:
 ColId
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 OptSchemaEltList:
 OptSchemaEltList schema_stmt
 { 
 $$ = cat_str(2,$1,$2);
}
| 
 { 
 $$=EMPTY; }
;


 schema_stmt:
 CreateStmt
 { 
 $$ = $1;
}
|  IndexStmt
 { 
 $$ = $1;
}
|  CreateSeqStmt
 { 
 $$ = $1;
}
|  CreateTrigStmt
 { 
 $$ = $1;
}
|  GrantStmt
 { 
 $$ = $1;
}
|  ViewStmt
 { 
 $$ = $1;
}
;


 VariableSetStmt:
 SET set_rest
 { 
 $$ = cat_str(2,mm_strdup("set"),$2);
}
|  SET LOCAL set_rest
 { 
 $$ = cat_str(2,mm_strdup("set local"),$3);
}
|  SET SESSION set_rest
 { 
 $$ = cat_str(2,mm_strdup("set session"),$3);
}
;


 set_rest:
 TRANSACTION transaction_mode_list
 { 
 $$ = cat_str(2,mm_strdup("transaction"),$2);
}
|  SESSION CHARACTERISTICS AS TRANSACTION transaction_mode_list
 { 
 $$ = cat_str(2,mm_strdup("session characteristics as transaction"),$5);
}
|  set_rest_more
 { 
 $$ = $1;
}
;


 generic_set:
 var_name TO var_list
 { 
 $$ = cat_str(3,$1,mm_strdup("to"),$3);
}
|  var_name '=' var_list
 { 
 $$ = cat_str(3,$1,mm_strdup("="),$3);
}
|  var_name TO DEFAULT
 { 
 $$ = cat_str(2,$1,mm_strdup("to default"));
}
|  var_name '=' DEFAULT
 { 
 $$ = cat_str(2,$1,mm_strdup("= default"));
}
;


 set_rest_more:
 generic_set
 { 
 $$ = $1;
}
|  var_name FROM CURRENT_P
 { 
 $$ = cat_str(2,$1,mm_strdup("from current"));
}
|  TIME ZONE zone_value
 { 
 $$ = cat_str(2,mm_strdup("time zone"),$3);
}
|  CATALOG_P ecpg_sconst
 { 
mmerror(PARSE_ERROR, ET_WARNING, "unsupported feature will be passed to server");
 $$ = cat_str(2,mm_strdup("catalog"),$2);
}
|  SCHEMA ecpg_sconst
 { 
 $$ = cat_str(2,mm_strdup("schema"),$2);
}
|  NAMES opt_encoding
 { 
 $$ = cat_str(2,mm_strdup("names"),$2);
}
|  ROLE NonReservedWord_or_Sconst
 { 
 $$ = cat_str(2,mm_strdup("role"),$2);
}
|  SESSION AUTHORIZATION NonReservedWord_or_Sconst
 { 
 $$ = cat_str(2,mm_strdup("session authorization"),$3);
}
|  SESSION AUTHORIZATION DEFAULT
 { 
 $$ = mm_strdup("session authorization default");
}
|  XML_P OPTION document_or_content
 { 
 $$ = cat_str(2,mm_strdup("xml option"),$3);
}
|  TRANSACTION SNAPSHOT ecpg_sconst
 { 
 $$ = cat_str(2,mm_strdup("transaction snapshot"),$3);
}
;


 var_name:
ECPGColId
 { 
 $$ = $1;
}
|  var_name '.' ColId
 { 
 $$ = cat_str(3,$1,mm_strdup("."),$3);
}
;


 var_list:
 var_value
 { 
 $$ = $1;
}
|  var_list ',' var_value
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 var_value:
 opt_boolean_or_string
 { 
 $$ = $1;
}
|  NumericOnly
 { 
		if ($1[0] == '$')
		{
			free($1);
			$1 = mm_strdup("$0");
		}

 $$ = $1;
}
;


 iso_level:
 READ UNCOMMITTED
 { 
 $$ = mm_strdup("read uncommitted");
}
|  READ COMMITTED
 { 
 $$ = mm_strdup("read committed");
}
|  REPEATABLE READ
 { 
 $$ = mm_strdup("repeatable read");
}
|  SERIALIZABLE
 { 
 $$ = mm_strdup("serializable");
}
;


 opt_boolean_or_string:
 TRUE_P
 { 
 $$ = mm_strdup("true");
}
|  FALSE_P
 { 
 $$ = mm_strdup("false");
}
|  ON
 { 
 $$ = mm_strdup("on");
}
|  NonReservedWord_or_Sconst
 { 
 $$ = $1;
}
;


 zone_value:
 ecpg_sconst
 { 
 $$ = $1;
}
|  ecpg_ident
 { 
 $$ = $1;
}
|  ConstInterval ecpg_sconst opt_interval
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  ConstInterval '(' Iconst ')' ecpg_sconst
 { 
 $$ = cat_str(5,$1,mm_strdup("("),$3,mm_strdup(")"),$5);
}
|  NumericOnly
 { 
 $$ = $1;
}
|  DEFAULT
 { 
 $$ = mm_strdup("default");
}
|  LOCAL
 { 
 $$ = mm_strdup("local");
}
;


 opt_encoding:
 ecpg_sconst
 { 
 $$ = $1;
}
|  DEFAULT
 { 
 $$ = mm_strdup("default");
}
| 
 { 
 $$=EMPTY; }
;


 NonReservedWord_or_Sconst:
 NonReservedWord
 { 
 $$ = $1;
}
|  ecpg_sconst
 { 
 $$ = $1;
}
;


 VariableResetStmt:
 RESET reset_rest
 { 
 $$ = cat_str(2,mm_strdup("reset"),$2);
}
;


 reset_rest:
 generic_reset
 { 
 $$ = $1;
}
|  TIME ZONE
 { 
 $$ = mm_strdup("time zone");
}
|  TRANSACTION ISOLATION LEVEL
 { 
 $$ = mm_strdup("transaction isolation level");
}
|  SESSION AUTHORIZATION
 { 
 $$ = mm_strdup("session authorization");
}
;


 generic_reset:
 var_name
 { 
 $$ = $1;
}
|  ALL
 { 
 $$ = mm_strdup("all");
}
;


 SetResetClause:
 SET set_rest
 { 
 $$ = cat_str(2,mm_strdup("set"),$2);
}
|  VariableResetStmt
 { 
 $$ = $1;
}
;


 FunctionSetResetClause:
 SET set_rest_more
 { 
 $$ = cat_str(2,mm_strdup("set"),$2);
}
|  VariableResetStmt
 { 
 $$ = $1;
}
;


 VariableShowStmt:
SHOW var_name ecpg_into
 { 
 $$ = cat_str(2,mm_strdup("show"),$2);
}
| SHOW TIME ZONE ecpg_into
 { 
 $$ = mm_strdup("show time zone");
}
| SHOW TRANSACTION ISOLATION LEVEL ecpg_into
 { 
 $$ = mm_strdup("show transaction isolation level");
}
| SHOW SESSION AUTHORIZATION ecpg_into
 { 
 $$ = mm_strdup("show session authorization");
}
|  SHOW ALL
	{
		mmerror(PARSE_ERROR, ET_ERROR, "SHOW ALL is not implemented");
		$$ = EMPTY;
	}
;


 ConstraintsSetStmt:
 SET CONSTRAINTS constraints_set_list constraints_set_mode
 { 
 $$ = cat_str(3,mm_strdup("set constraints"),$3,$4);
}
;


 constraints_set_list:
 ALL
 { 
 $$ = mm_strdup("all");
}
|  qualified_name_list
 { 
 $$ = $1;
}
;


 constraints_set_mode:
 DEFERRED
 { 
 $$ = mm_strdup("deferred");
}
|  IMMEDIATE
 { 
 $$ = mm_strdup("immediate");
}
;


 CheckPointStmt:
 CHECKPOINT
 { 
 $$ = mm_strdup("checkpoint");
}
;


 DiscardStmt:
 DISCARD ALL
 { 
 $$ = mm_strdup("discard all");
}
|  DISCARD TEMP
 { 
 $$ = mm_strdup("discard temp");
}
|  DISCARD TEMPORARY
 { 
 $$ = mm_strdup("discard temporary");
}
|  DISCARD PLANS
 { 
 $$ = mm_strdup("discard plans");
}
|  DISCARD SEQUENCES
 { 
 $$ = mm_strdup("discard sequences");
}
;


 AlterTableStmt:
 ALTER TABLE relation_expr alter_table_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter table"),$3,$4);
}
|  ALTER TABLE IF_P EXISTS relation_expr alter_table_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter table if exists"),$5,$6);
}
|  ALTER TABLE relation_expr partition_cmd
 { 
 $$ = cat_str(3,mm_strdup("alter table"),$3,$4);
}
|  ALTER TABLE IF_P EXISTS relation_expr partition_cmd
 { 
 $$ = cat_str(3,mm_strdup("alter table if exists"),$5,$6);
}
|  ALTER TABLE ALL IN_P TABLESPACE name SET TABLESPACE name opt_nowait
 { 
 $$ = cat_str(5,mm_strdup("alter table all in tablespace"),$6,mm_strdup("set tablespace"),$9,$10);
}
|  ALTER TABLE ALL IN_P TABLESPACE name OWNED BY role_list SET TABLESPACE name opt_nowait
 { 
 $$ = cat_str(7,mm_strdup("alter table all in tablespace"),$6,mm_strdup("owned by"),$9,mm_strdup("set tablespace"),$12,$13);
}
|  ALTER INDEX qualified_name alter_table_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter index"),$3,$4);
}
|  ALTER INDEX IF_P EXISTS qualified_name alter_table_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter index if exists"),$5,$6);
}
|  ALTER INDEX qualified_name index_partition_cmd
 { 
 $$ = cat_str(3,mm_strdup("alter index"),$3,$4);
}
|  ALTER INDEX ALL IN_P TABLESPACE name SET TABLESPACE name opt_nowait
 { 
 $$ = cat_str(5,mm_strdup("alter index all in tablespace"),$6,mm_strdup("set tablespace"),$9,$10);
}
|  ALTER INDEX ALL IN_P TABLESPACE name OWNED BY role_list SET TABLESPACE name opt_nowait
 { 
 $$ = cat_str(7,mm_strdup("alter index all in tablespace"),$6,mm_strdup("owned by"),$9,mm_strdup("set tablespace"),$12,$13);
}
|  ALTER SEQUENCE qualified_name alter_table_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter sequence"),$3,$4);
}
|  ALTER SEQUENCE IF_P EXISTS qualified_name alter_table_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter sequence if exists"),$5,$6);
}
|  ALTER VIEW qualified_name alter_table_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter view"),$3,$4);
}
|  ALTER VIEW IF_P EXISTS qualified_name alter_table_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter view if exists"),$5,$6);
}
|  ALTER MATERIALIZED VIEW qualified_name alter_table_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter materialized view"),$4,$5);
}
|  ALTER MATERIALIZED VIEW IF_P EXISTS qualified_name alter_table_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter materialized view if exists"),$6,$7);
}
|  ALTER MATERIALIZED VIEW ALL IN_P TABLESPACE name SET TABLESPACE name opt_nowait
 { 
 $$ = cat_str(5,mm_strdup("alter materialized view all in tablespace"),$7,mm_strdup("set tablespace"),$10,$11);
}
|  ALTER MATERIALIZED VIEW ALL IN_P TABLESPACE name OWNED BY role_list SET TABLESPACE name opt_nowait
 { 
 $$ = cat_str(7,mm_strdup("alter materialized view all in tablespace"),$7,mm_strdup("owned by"),$10,mm_strdup("set tablespace"),$13,$14);
}
|  ALTER FOREIGN TABLE relation_expr alter_table_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter foreign table"),$4,$5);
}
|  ALTER FOREIGN TABLE IF_P EXISTS relation_expr alter_table_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter foreign table if exists"),$6,$7);
}
;


 alter_table_cmds:
 alter_table_cmd
 { 
 $$ = $1;
}
|  alter_table_cmds ',' alter_table_cmd
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 partition_cmd:
 ATTACH PARTITION qualified_name PartitionBoundSpec
 { 
 $$ = cat_str(3,mm_strdup("attach partition"),$3,$4);
}
|  DETACH PARTITION qualified_name opt_concurrently
 { 
 $$ = cat_str(3,mm_strdup("detach partition"),$3,$4);
}
|  DETACH PARTITION qualified_name FINALIZE
 { 
 $$ = cat_str(3,mm_strdup("detach partition"),$3,mm_strdup("finalize"));
}
;


 index_partition_cmd:
 ATTACH PARTITION qualified_name
 { 
 $$ = cat_str(2,mm_strdup("attach partition"),$3);
}
;


 alter_table_cmd:
 ADD_P columnDef
 { 
 $$ = cat_str(2,mm_strdup("add"),$2);
}
|  ADD_P IF_P NOT EXISTS columnDef
 { 
 $$ = cat_str(2,mm_strdup("add if not exists"),$5);
}
|  ADD_P COLUMN columnDef
 { 
 $$ = cat_str(2,mm_strdup("add column"),$3);
}
|  ADD_P COLUMN IF_P NOT EXISTS columnDef
 { 
 $$ = cat_str(2,mm_strdup("add column if not exists"),$6);
}
|  ALTER opt_column ColId alter_column_default
 { 
 $$ = cat_str(4,mm_strdup("alter"),$2,$3,$4);
}
|  ALTER opt_column ColId DROP NOT NULL_P
 { 
 $$ = cat_str(4,mm_strdup("alter"),$2,$3,mm_strdup("drop not null"));
}
|  ALTER opt_column ColId SET NOT NULL_P
 { 
 $$ = cat_str(4,mm_strdup("alter"),$2,$3,mm_strdup("set not null"));
}
|  ALTER opt_column ColId DROP EXPRESSION
 { 
 $$ = cat_str(4,mm_strdup("alter"),$2,$3,mm_strdup("drop expression"));
}
|  ALTER opt_column ColId DROP EXPRESSION IF_P EXISTS
 { 
 $$ = cat_str(4,mm_strdup("alter"),$2,$3,mm_strdup("drop expression if exists"));
}
|  ALTER opt_column ColId SET STATISTICS SignedIconst
 { 
 $$ = cat_str(5,mm_strdup("alter"),$2,$3,mm_strdup("set statistics"),$6);
}
|  ALTER opt_column Iconst SET STATISTICS SignedIconst
 { 
 $$ = cat_str(5,mm_strdup("alter"),$2,$3,mm_strdup("set statistics"),$6);
}
|  ALTER opt_column ColId SET reloptions
 { 
 $$ = cat_str(5,mm_strdup("alter"),$2,$3,mm_strdup("set"),$5);
}
|  ALTER opt_column ColId RESET reloptions
 { 
 $$ = cat_str(5,mm_strdup("alter"),$2,$3,mm_strdup("reset"),$5);
}
|  ALTER opt_column ColId SET STORAGE ColId
 { 
 $$ = cat_str(5,mm_strdup("alter"),$2,$3,mm_strdup("set storage"),$6);
}
|  ALTER opt_column ColId SET column_compression
 { 
 $$ = cat_str(5,mm_strdup("alter"),$2,$3,mm_strdup("set"),$5);
}
|  ALTER opt_column ColId ADD_P GENERATED generated_when AS IDENTITY_P OptParenthesizedSeqOptList
 { 
 $$ = cat_str(7,mm_strdup("alter"),$2,$3,mm_strdup("add generated"),$6,mm_strdup("as identity"),$9);
}
|  ALTER opt_column ColId alter_identity_column_option_list
 { 
 $$ = cat_str(4,mm_strdup("alter"),$2,$3,$4);
}
|  ALTER opt_column ColId DROP IDENTITY_P
 { 
 $$ = cat_str(4,mm_strdup("alter"),$2,$3,mm_strdup("drop identity"));
}
|  ALTER opt_column ColId DROP IDENTITY_P IF_P EXISTS
 { 
 $$ = cat_str(4,mm_strdup("alter"),$2,$3,mm_strdup("drop identity if exists"));
}
|  DROP opt_column IF_P EXISTS ColId opt_drop_behavior
 { 
 $$ = cat_str(5,mm_strdup("drop"),$2,mm_strdup("if exists"),$5,$6);
}
|  DROP opt_column ColId opt_drop_behavior
 { 
 $$ = cat_str(4,mm_strdup("drop"),$2,$3,$4);
}
|  ALTER opt_column ColId opt_set_data TYPE_P Typename opt_collate_clause alter_using
 { 
 $$ = cat_str(8,mm_strdup("alter"),$2,$3,$4,mm_strdup("type"),$6,$7,$8);
}
|  ALTER opt_column ColId alter_generic_options
 { 
 $$ = cat_str(4,mm_strdup("alter"),$2,$3,$4);
}
|  ADD_P TableConstraint
 { 
 $$ = cat_str(2,mm_strdup("add"),$2);
}
|  ALTER CONSTRAINT name ConstraintAttributeSpec
 { 
 $$ = cat_str(3,mm_strdup("alter constraint"),$3,$4);
}
|  VALIDATE CONSTRAINT name
 { 
 $$ = cat_str(2,mm_strdup("validate constraint"),$3);
}
|  DROP CONSTRAINT IF_P EXISTS name opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop constraint if exists"),$5,$6);
}
|  DROP CONSTRAINT name opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop constraint"),$3,$4);
}
|  SET WITHOUT OIDS
 { 
 $$ = mm_strdup("set without oids");
}
|  CLUSTER ON name
 { 
 $$ = cat_str(2,mm_strdup("cluster on"),$3);
}
|  SET WITHOUT CLUSTER
 { 
 $$ = mm_strdup("set without cluster");
}
|  SET LOGGED
 { 
 $$ = mm_strdup("set logged");
}
|  SET UNLOGGED
 { 
 $$ = mm_strdup("set unlogged");
}
|  ENABLE_P TRIGGER name
 { 
 $$ = cat_str(2,mm_strdup("enable trigger"),$3);
}
|  ENABLE_P ALWAYS TRIGGER name
 { 
 $$ = cat_str(2,mm_strdup("enable always trigger"),$4);
}
|  ENABLE_P REPLICA TRIGGER name
 { 
 $$ = cat_str(2,mm_strdup("enable replica trigger"),$4);
}
|  ENABLE_P TRIGGER ALL
 { 
 $$ = mm_strdup("enable trigger all");
}
|  ENABLE_P TRIGGER USER
 { 
 $$ = mm_strdup("enable trigger user");
}
|  DISABLE_P TRIGGER name
 { 
 $$ = cat_str(2,mm_strdup("disable trigger"),$3);
}
|  DISABLE_P TRIGGER ALL
 { 
 $$ = mm_strdup("disable trigger all");
}
|  DISABLE_P TRIGGER USER
 { 
 $$ = mm_strdup("disable trigger user");
}
|  ENABLE_P RULE name
 { 
 $$ = cat_str(2,mm_strdup("enable rule"),$3);
}
|  ENABLE_P ALWAYS RULE name
 { 
 $$ = cat_str(2,mm_strdup("enable always rule"),$4);
}
|  ENABLE_P REPLICA RULE name
 { 
 $$ = cat_str(2,mm_strdup("enable replica rule"),$4);
}
|  DISABLE_P RULE name
 { 
 $$ = cat_str(2,mm_strdup("disable rule"),$3);
}
|  INHERIT qualified_name
 { 
 $$ = cat_str(2,mm_strdup("inherit"),$2);
}
|  NO INHERIT qualified_name
 { 
 $$ = cat_str(2,mm_strdup("no inherit"),$3);
}
|  OF any_name
 { 
 $$ = cat_str(2,mm_strdup("of"),$2);
}
|  NOT OF
 { 
 $$ = mm_strdup("not of");
}
|  OWNER TO RoleSpec
 { 
 $$ = cat_str(2,mm_strdup("owner to"),$3);
}
|  SET TABLESPACE name
 { 
 $$ = cat_str(2,mm_strdup("set tablespace"),$3);
}
|  SET reloptions
 { 
 $$ = cat_str(2,mm_strdup("set"),$2);
}
|  RESET reloptions
 { 
 $$ = cat_str(2,mm_strdup("reset"),$2);
}
|  REPLICA IDENTITY_P replica_identity
 { 
 $$ = cat_str(2,mm_strdup("replica identity"),$3);
}
|  ENABLE_P ROW LEVEL SECURITY
 { 
 $$ = mm_strdup("enable row level security");
}
|  DISABLE_P ROW LEVEL SECURITY
 { 
 $$ = mm_strdup("disable row level security");
}
|  FORCE ROW LEVEL SECURITY
 { 
 $$ = mm_strdup("force row level security");
}
|  NO FORCE ROW LEVEL SECURITY
 { 
 $$ = mm_strdup("no force row level security");
}
|  alter_generic_options
 { 
 $$ = $1;
}
;


 alter_column_default:
 SET DEFAULT a_expr
 { 
 $$ = cat_str(2,mm_strdup("set default"),$3);
}
|  DROP DEFAULT
 { 
 $$ = mm_strdup("drop default");
}
;


 opt_drop_behavior:
 CASCADE
 { 
 $$ = mm_strdup("cascade");
}
|  RESTRICT
 { 
 $$ = mm_strdup("restrict");
}
| 
 { 
 $$=EMPTY; }
;


 opt_collate_clause:
 COLLATE any_name
 { 
 $$ = cat_str(2,mm_strdup("collate"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 alter_using:
 USING a_expr
 { 
 $$ = cat_str(2,mm_strdup("using"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 replica_identity:
 NOTHING
 { 
 $$ = mm_strdup("nothing");
}
|  FULL
 { 
 $$ = mm_strdup("full");
}
|  DEFAULT
 { 
 $$ = mm_strdup("default");
}
|  USING INDEX name
 { 
 $$ = cat_str(2,mm_strdup("using index"),$3);
}
;


 reloptions:
 '(' reloption_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
;


 opt_reloptions:
 WITH reloptions
 { 
 $$ = cat_str(2,mm_strdup("with"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 reloption_list:
 reloption_elem
 { 
 $$ = $1;
}
|  reloption_list ',' reloption_elem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 reloption_elem:
 ColLabel '=' def_arg
 { 
 $$ = cat_str(3,$1,mm_strdup("="),$3);
}
|  ColLabel
 { 
 $$ = $1;
}
|  ColLabel '.' ColLabel '=' def_arg
 { 
 $$ = cat_str(5,$1,mm_strdup("."),$3,mm_strdup("="),$5);
}
|  ColLabel '.' ColLabel
 { 
 $$ = cat_str(3,$1,mm_strdup("."),$3);
}
;


 alter_identity_column_option_list:
 alter_identity_column_option
 { 
 $$ = $1;
}
|  alter_identity_column_option_list alter_identity_column_option
 { 
 $$ = cat_str(2,$1,$2);
}
;


 alter_identity_column_option:
 RESTART
 { 
 $$ = mm_strdup("restart");
}
|  RESTART opt_with NumericOnly
 { 
 $$ = cat_str(3,mm_strdup("restart"),$2,$3);
}
|  SET SeqOptElem
 { 
 $$ = cat_str(2,mm_strdup("set"),$2);
}
|  SET GENERATED generated_when
 { 
 $$ = cat_str(2,mm_strdup("set generated"),$3);
}
;


 PartitionBoundSpec:
 FOR VALUES WITH '(' hash_partbound ')'
 { 
 $$ = cat_str(3,mm_strdup("for values with ("),$5,mm_strdup(")"));
}
|  FOR VALUES IN_P '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("for values in ("),$5,mm_strdup(")"));
}
|  FOR VALUES FROM '(' expr_list ')' TO '(' expr_list ')'
 { 
 $$ = cat_str(5,mm_strdup("for values from ("),$5,mm_strdup(") to ("),$9,mm_strdup(")"));
}
|  DEFAULT
 { 
 $$ = mm_strdup("default");
}
;


 hash_partbound_elem:
 NonReservedWord Iconst
 { 
 $$ = cat_str(2,$1,$2);
}
;


 hash_partbound:
 hash_partbound_elem
 { 
 $$ = $1;
}
|  hash_partbound ',' hash_partbound_elem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 AlterCompositeTypeStmt:
 ALTER TYPE_P any_name alter_type_cmds
 { 
 $$ = cat_str(3,mm_strdup("alter type"),$3,$4);
}
;


 alter_type_cmds:
 alter_type_cmd
 { 
 $$ = $1;
}
|  alter_type_cmds ',' alter_type_cmd
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 alter_type_cmd:
 ADD_P ATTRIBUTE TableFuncElement opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("add attribute"),$3,$4);
}
|  DROP ATTRIBUTE IF_P EXISTS ColId opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop attribute if exists"),$5,$6);
}
|  DROP ATTRIBUTE ColId opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop attribute"),$3,$4);
}
|  ALTER ATTRIBUTE ColId opt_set_data TYPE_P Typename opt_collate_clause opt_drop_behavior
 { 
 $$ = cat_str(7,mm_strdup("alter attribute"),$3,$4,mm_strdup("type"),$6,$7,$8);
}
;


 ClosePortalStmt:
 CLOSE cursor_name
	{
		char *cursor_marker = $2[0] == ':' ? mm_strdup("$0") : $2;
		struct cursor *ptr = NULL;
		for (ptr = cur; ptr != NULL; ptr = ptr -> next)
		{
			if (strcmp($2, ptr -> name) == 0)
			{
				if (ptr -> connection)
					connection = mm_strdup(ptr -> connection);

				break;
			}
		}
		$$ = cat2_str(mm_strdup("close"), cursor_marker);
	}
|  CLOSE ALL
 { 
 $$ = mm_strdup("close all");
}
;


 CopyStmt:
 COPY opt_binary qualified_name opt_column_list copy_from opt_program copy_file_name copy_delimiter opt_with copy_options where_clause
 { 
			if (strcmp($5, "from") == 0 &&
			   (strcmp($7, "stdin") == 0 || strcmp($7, "stdout") == 0))
				mmerror(PARSE_ERROR, ET_WARNING, "COPY FROM STDIN is not implemented");

 $$ = cat_str(11,mm_strdup("copy"),$2,$3,$4,$5,$6,$7,$8,$9,$10,$11);
}
|  COPY '(' PreparableStmt ')' TO opt_program copy_file_name opt_with copy_options
 { 
 $$ = cat_str(7,mm_strdup("copy ("),$3,mm_strdup(") to"),$6,$7,$8,$9);
}
;


 copy_from:
 FROM
 { 
 $$ = mm_strdup("from");
}
|  TO
 { 
 $$ = mm_strdup("to");
}
;


 opt_program:
 PROGRAM
 { 
 $$ = mm_strdup("program");
}
| 
 { 
 $$=EMPTY; }
;


 copy_file_name:
 ecpg_sconst
 { 
 $$ = $1;
}
|  STDIN
 { 
 $$ = mm_strdup("stdin");
}
|  STDOUT
 { 
 $$ = mm_strdup("stdout");
}
;


 copy_options:
 copy_opt_list
 { 
 $$ = $1;
}
|  '(' copy_generic_opt_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
;


 copy_opt_list:
 copy_opt_list copy_opt_item
 { 
 $$ = cat_str(2,$1,$2);
}
| 
 { 
 $$=EMPTY; }
;


 copy_opt_item:
 BINARY
 { 
 $$ = mm_strdup("binary");
}
|  FREEZE
 { 
 $$ = mm_strdup("freeze");
}
|  DELIMITER opt_as ecpg_sconst
 { 
 $$ = cat_str(3,mm_strdup("delimiter"),$2,$3);
}
|  NULL_P opt_as ecpg_sconst
 { 
 $$ = cat_str(3,mm_strdup("null"),$2,$3);
}
|  CSV
 { 
 $$ = mm_strdup("csv");
}
|  HEADER_P
 { 
 $$ = mm_strdup("header");
}
|  QUOTE opt_as ecpg_sconst
 { 
 $$ = cat_str(3,mm_strdup("quote"),$2,$3);
}
|  ESCAPE opt_as ecpg_sconst
 { 
 $$ = cat_str(3,mm_strdup("escape"),$2,$3);
}
|  FORCE QUOTE columnList
 { 
 $$ = cat_str(2,mm_strdup("force quote"),$3);
}
|  FORCE QUOTE '*'
 { 
 $$ = mm_strdup("force quote *");
}
|  FORCE NOT NULL_P columnList
 { 
 $$ = cat_str(2,mm_strdup("force not null"),$4);
}
|  FORCE NULL_P columnList
 { 
 $$ = cat_str(2,mm_strdup("force null"),$3);
}
|  ENCODING ecpg_sconst
 { 
 $$ = cat_str(2,mm_strdup("encoding"),$2);
}
;


 opt_binary:
 BINARY
 { 
 $$ = mm_strdup("binary");
}
| 
 { 
 $$=EMPTY; }
;


 copy_delimiter:
 opt_using DELIMITERS ecpg_sconst
 { 
 $$ = cat_str(3,$1,mm_strdup("delimiters"),$3);
}
| 
 { 
 $$=EMPTY; }
;


 opt_using:
 USING
 { 
 $$ = mm_strdup("using");
}
| 
 { 
 $$=EMPTY; }
;


 copy_generic_opt_list:
 copy_generic_opt_elem
 { 
 $$ = $1;
}
|  copy_generic_opt_list ',' copy_generic_opt_elem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 copy_generic_opt_elem:
 ColLabel copy_generic_opt_arg
 { 
 $$ = cat_str(2,$1,$2);
}
;


 copy_generic_opt_arg:
 opt_boolean_or_string
 { 
 $$ = $1;
}
|  NumericOnly
 { 
 $$ = $1;
}
|  '*'
 { 
 $$ = mm_strdup("*");
}
|  '(' copy_generic_opt_arg_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 copy_generic_opt_arg_list:
 copy_generic_opt_arg_list_item
 { 
 $$ = $1;
}
|  copy_generic_opt_arg_list ',' copy_generic_opt_arg_list_item
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 copy_generic_opt_arg_list_item:
 opt_boolean_or_string
 { 
 $$ = $1;
}
;


 CreateStmt:
 CREATE OptTemp TABLE qualified_name '(' OptTableElementList ')' OptInherit OptPartitionSpec table_access_method_clause OptWith OnCommitOption OptTableSpace
 { 
 $$ = cat_str(13,mm_strdup("create"),$2,mm_strdup("table"),$4,mm_strdup("("),$6,mm_strdup(")"),$8,$9,$10,$11,$12,$13);
}
|  CREATE OptTemp TABLE IF_P NOT EXISTS qualified_name '(' OptTableElementList ')' OptInherit OptPartitionSpec table_access_method_clause OptWith OnCommitOption OptTableSpace
 { 
 $$ = cat_str(13,mm_strdup("create"),$2,mm_strdup("table if not exists"),$7,mm_strdup("("),$9,mm_strdup(")"),$11,$12,$13,$14,$15,$16);
}
|  CREATE OptTemp TABLE qualified_name OF any_name OptTypedTableElementList OptPartitionSpec table_access_method_clause OptWith OnCommitOption OptTableSpace
 { 
 $$ = cat_str(12,mm_strdup("create"),$2,mm_strdup("table"),$4,mm_strdup("of"),$6,$7,$8,$9,$10,$11,$12);
}
|  CREATE OptTemp TABLE IF_P NOT EXISTS qualified_name OF any_name OptTypedTableElementList OptPartitionSpec table_access_method_clause OptWith OnCommitOption OptTableSpace
 { 
 $$ = cat_str(12,mm_strdup("create"),$2,mm_strdup("table if not exists"),$7,mm_strdup("of"),$9,$10,$11,$12,$13,$14,$15);
}
|  CREATE OptTemp TABLE qualified_name PARTITION OF qualified_name OptTypedTableElementList PartitionBoundSpec OptPartitionSpec table_access_method_clause OptWith OnCommitOption OptTableSpace
 { 
 $$ = cat_str(13,mm_strdup("create"),$2,mm_strdup("table"),$4,mm_strdup("partition of"),$7,$8,$9,$10,$11,$12,$13,$14);
}
|  CREATE OptTemp TABLE IF_P NOT EXISTS qualified_name PARTITION OF qualified_name OptTypedTableElementList PartitionBoundSpec OptPartitionSpec table_access_method_clause OptWith OnCommitOption OptTableSpace
 { 
 $$ = cat_str(13,mm_strdup("create"),$2,mm_strdup("table if not exists"),$7,mm_strdup("partition of"),$10,$11,$12,$13,$14,$15,$16,$17);
}
;


 OptTemp:
 TEMPORARY
 { 
 $$ = mm_strdup("temporary");
}
|  TEMP
 { 
 $$ = mm_strdup("temp");
}
|  LOCAL TEMPORARY
 { 
 $$ = mm_strdup("local temporary");
}
|  LOCAL TEMP
 { 
 $$ = mm_strdup("local temp");
}
|  GLOBAL TEMPORARY
 { 
 $$ = mm_strdup("global temporary");
}
|  GLOBAL TEMP
 { 
 $$ = mm_strdup("global temp");
}
|  UNLOGGED
 { 
 $$ = mm_strdup("unlogged");
}
| 
 { 
 $$=EMPTY; }
;


 OptTableElementList:
 TableElementList
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 OptTypedTableElementList:
 '(' TypedTableElementList ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 TableElementList:
 TableElement
 { 
 $$ = $1;
}
|  TableElementList ',' TableElement
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 TypedTableElementList:
 TypedTableElement
 { 
 $$ = $1;
}
|  TypedTableElementList ',' TypedTableElement
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 TableElement:
 columnDef
 { 
 $$ = $1;
}
|  TableLikeClause
 { 
 $$ = $1;
}
|  TableConstraint
 { 
 $$ = $1;
}
;


 TypedTableElement:
 columnOptions
 { 
 $$ = $1;
}
|  TableConstraint
 { 
 $$ = $1;
}
;


 columnDef:
 ColId Typename opt_column_compression create_generic_options ColQualList
 { 
 $$ = cat_str(5,$1,$2,$3,$4,$5);
}
;


 columnOptions:
 ColId ColQualList
 { 
 $$ = cat_str(2,$1,$2);
}
|  ColId WITH OPTIONS ColQualList
 { 
 $$ = cat_str(3,$1,mm_strdup("with options"),$4);
}
;


 column_compression:
 COMPRESSION ColId
 { 
 $$ = cat_str(2,mm_strdup("compression"),$2);
}
|  COMPRESSION DEFAULT
 { 
 $$ = mm_strdup("compression default");
}
;


 opt_column_compression:
 column_compression
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 ColQualList:
 ColQualList ColConstraint
 { 
 $$ = cat_str(2,$1,$2);
}
| 
 { 
 $$=EMPTY; }
;


 ColConstraint:
 CONSTRAINT name ColConstraintElem
 { 
 $$ = cat_str(3,mm_strdup("constraint"),$2,$3);
}
|  ColConstraintElem
 { 
 $$ = $1;
}
|  ConstraintAttr
 { 
 $$ = $1;
}
|  COLLATE any_name
 { 
 $$ = cat_str(2,mm_strdup("collate"),$2);
}
;


 ColConstraintElem:
 NOT NULL_P
 { 
 $$ = mm_strdup("not null");
}
|  NULL_P
 { 
 $$ = mm_strdup("null");
}
|  UNIQUE opt_definition OptConsTableSpace
 { 
 $$ = cat_str(3,mm_strdup("unique"),$2,$3);
}
|  PRIMARY KEY opt_definition OptConsTableSpace
 { 
 $$ = cat_str(3,mm_strdup("primary key"),$3,$4);
}
|  CHECK '(' a_expr ')' opt_no_inherit
 { 
 $$ = cat_str(4,mm_strdup("check ("),$3,mm_strdup(")"),$5);
}
|  DEFAULT b_expr
 { 
 $$ = cat_str(2,mm_strdup("default"),$2);
}
|  GENERATED generated_when AS IDENTITY_P OptParenthesizedSeqOptList
 { 
 $$ = cat_str(4,mm_strdup("generated"),$2,mm_strdup("as identity"),$5);
}
|  GENERATED generated_when AS '(' a_expr ')' STORED
 { 
 $$ = cat_str(5,mm_strdup("generated"),$2,mm_strdup("as ("),$5,mm_strdup(") stored"));
}
|  REFERENCES qualified_name opt_column_list key_match key_actions
 { 
 $$ = cat_str(5,mm_strdup("references"),$2,$3,$4,$5);
}
;


 generated_when:
 ALWAYS
 { 
 $$ = mm_strdup("always");
}
|  BY DEFAULT
 { 
 $$ = mm_strdup("by default");
}
;


 ConstraintAttr:
 DEFERRABLE
 { 
 $$ = mm_strdup("deferrable");
}
|  NOT DEFERRABLE
 { 
 $$ = mm_strdup("not deferrable");
}
|  INITIALLY DEFERRED
 { 
 $$ = mm_strdup("initially deferred");
}
|  INITIALLY IMMEDIATE
 { 
 $$ = mm_strdup("initially immediate");
}
;


 TableLikeClause:
 LIKE qualified_name TableLikeOptionList
 { 
 $$ = cat_str(3,mm_strdup("like"),$2,$3);
}
;


 TableLikeOptionList:
 TableLikeOptionList INCLUDING TableLikeOption
 { 
 $$ = cat_str(3,$1,mm_strdup("including"),$3);
}
|  TableLikeOptionList EXCLUDING TableLikeOption
 { 
 $$ = cat_str(3,$1,mm_strdup("excluding"),$3);
}
| 
 { 
 $$=EMPTY; }
;


 TableLikeOption:
 COMMENTS
 { 
 $$ = mm_strdup("comments");
}
|  COMPRESSION
 { 
 $$ = mm_strdup("compression");
}
|  CONSTRAINTS
 { 
 $$ = mm_strdup("constraints");
}
|  DEFAULTS
 { 
 $$ = mm_strdup("defaults");
}
|  IDENTITY_P
 { 
 $$ = mm_strdup("identity");
}
|  GENERATED
 { 
 $$ = mm_strdup("generated");
}
|  INDEXES
 { 
 $$ = mm_strdup("indexes");
}
|  STATISTICS
 { 
 $$ = mm_strdup("statistics");
}
|  STORAGE
 { 
 $$ = mm_strdup("storage");
}
|  ALL
 { 
 $$ = mm_strdup("all");
}
;


 TableConstraint:
 CONSTRAINT name ConstraintElem
 { 
 $$ = cat_str(3,mm_strdup("constraint"),$2,$3);
}
|  ConstraintElem
 { 
 $$ = $1;
}
;


 ConstraintElem:
 CHECK '(' a_expr ')' ConstraintAttributeSpec
 { 
 $$ = cat_str(4,mm_strdup("check ("),$3,mm_strdup(")"),$5);
}
|  UNIQUE '(' columnList ')' opt_c_include opt_definition OptConsTableSpace ConstraintAttributeSpec
 { 
 $$ = cat_str(7,mm_strdup("unique ("),$3,mm_strdup(")"),$5,$6,$7,$8);
}
|  UNIQUE ExistingIndex ConstraintAttributeSpec
 { 
 $$ = cat_str(3,mm_strdup("unique"),$2,$3);
}
|  PRIMARY KEY '(' columnList ')' opt_c_include opt_definition OptConsTableSpace ConstraintAttributeSpec
 { 
 $$ = cat_str(7,mm_strdup("primary key ("),$4,mm_strdup(")"),$6,$7,$8,$9);
}
|  PRIMARY KEY ExistingIndex ConstraintAttributeSpec
 { 
 $$ = cat_str(3,mm_strdup("primary key"),$3,$4);
}
|  EXCLUDE access_method_clause '(' ExclusionConstraintList ')' opt_c_include opt_definition OptConsTableSpace OptWhereClause ConstraintAttributeSpec
 { 
 $$ = cat_str(10,mm_strdup("exclude"),$2,mm_strdup("("),$4,mm_strdup(")"),$6,$7,$8,$9,$10);
}
|  FOREIGN KEY '(' columnList ')' REFERENCES qualified_name opt_column_list key_match key_actions ConstraintAttributeSpec
 { 
 $$ = cat_str(8,mm_strdup("foreign key ("),$4,mm_strdup(") references"),$7,$8,$9,$10,$11);
}
;


 opt_no_inherit:
 NO INHERIT
 { 
 $$ = mm_strdup("no inherit");
}
| 
 { 
 $$=EMPTY; }
;


 opt_column_list:
 '(' columnList ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 columnList:
 columnElem
 { 
 $$ = $1;
}
|  columnList ',' columnElem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 columnElem:
 ColId
 { 
 $$ = $1;
}
;


 opt_c_include:
 INCLUDE '(' columnList ')'
 { 
 $$ = cat_str(3,mm_strdup("include ("),$3,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 key_match:
 MATCH FULL
 { 
 $$ = mm_strdup("match full");
}
|  MATCH PARTIAL
 { 
mmerror(PARSE_ERROR, ET_WARNING, "unsupported feature will be passed to server");
 $$ = mm_strdup("match partial");
}
|  MATCH SIMPLE
 { 
 $$ = mm_strdup("match simple");
}
| 
 { 
 $$=EMPTY; }
;


 ExclusionConstraintList:
 ExclusionConstraintElem
 { 
 $$ = $1;
}
|  ExclusionConstraintList ',' ExclusionConstraintElem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 ExclusionConstraintElem:
 index_elem WITH any_operator
 { 
 $$ = cat_str(3,$1,mm_strdup("with"),$3);
}
|  index_elem WITH OPERATOR '(' any_operator ')'
 { 
 $$ = cat_str(4,$1,mm_strdup("with operator ("),$5,mm_strdup(")"));
}
;


 OptWhereClause:
 WHERE '(' a_expr ')'
 { 
 $$ = cat_str(3,mm_strdup("where ("),$3,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 key_actions:
 key_update
 { 
 $$ = $1;
}
|  key_delete
 { 
 $$ = $1;
}
|  key_update key_delete
 { 
 $$ = cat_str(2,$1,$2);
}
|  key_delete key_update
 { 
 $$ = cat_str(2,$1,$2);
}
| 
 { 
 $$=EMPTY; }
;


 key_update:
 ON UPDATE key_action
 { 
 $$ = cat_str(2,mm_strdup("on update"),$3);
}
;


 key_delete:
 ON DELETE_P key_action
 { 
 $$ = cat_str(2,mm_strdup("on delete"),$3);
}
;


 key_action:
 NO ACTION
 { 
 $$ = mm_strdup("no action");
}
|  RESTRICT
 { 
 $$ = mm_strdup("restrict");
}
|  CASCADE
 { 
 $$ = mm_strdup("cascade");
}
|  SET NULL_P
 { 
 $$ = mm_strdup("set null");
}
|  SET DEFAULT
 { 
 $$ = mm_strdup("set default");
}
;


 OptInherit:
 INHERITS '(' qualified_name_list ')'
 { 
 $$ = cat_str(3,mm_strdup("inherits ("),$3,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 OptPartitionSpec:
 PartitionSpec
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 PartitionSpec:
 PARTITION BY ColId '(' part_params ')'
 { 
 $$ = cat_str(5,mm_strdup("partition by"),$3,mm_strdup("("),$5,mm_strdup(")"));
}
;


 part_params:
 part_elem
 { 
 $$ = $1;
}
|  part_params ',' part_elem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 part_elem:
 ColId opt_collate opt_class
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  func_expr_windowless opt_collate opt_class
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  '(' a_expr ')' opt_collate opt_class
 { 
 $$ = cat_str(5,mm_strdup("("),$2,mm_strdup(")"),$4,$5);
}
;


 table_access_method_clause:
 USING name
 { 
 $$ = cat_str(2,mm_strdup("using"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 OptWith:
 WITH reloptions
 { 
 $$ = cat_str(2,mm_strdup("with"),$2);
}
|  WITHOUT OIDS
 { 
 $$ = mm_strdup("without oids");
}
| 
 { 
 $$=EMPTY; }
;


 OnCommitOption:
 ON COMMIT DROP
 { 
 $$ = mm_strdup("on commit drop");
}
|  ON COMMIT DELETE_P ROWS
 { 
 $$ = mm_strdup("on commit delete rows");
}
|  ON COMMIT PRESERVE ROWS
 { 
 $$ = mm_strdup("on commit preserve rows");
}
| 
 { 
 $$=EMPTY; }
;


 OptTableSpace:
 TABLESPACE name
 { 
 $$ = cat_str(2,mm_strdup("tablespace"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 OptConsTableSpace:
 USING INDEX TABLESPACE name
 { 
 $$ = cat_str(2,mm_strdup("using index tablespace"),$4);
}
| 
 { 
 $$=EMPTY; }
;


 ExistingIndex:
 USING INDEX name
 { 
 $$ = cat_str(2,mm_strdup("using index"),$3);
}
;


 CreateStatsStmt:
 CREATE STATISTICS any_name opt_name_list ON stats_params FROM from_list
 { 
 $$ = cat_str(7,mm_strdup("create statistics"),$3,$4,mm_strdup("on"),$6,mm_strdup("from"),$8);
}
|  CREATE STATISTICS IF_P NOT EXISTS any_name opt_name_list ON stats_params FROM from_list
 { 
 $$ = cat_str(7,mm_strdup("create statistics if not exists"),$6,$7,mm_strdup("on"),$9,mm_strdup("from"),$11);
}
;


 stats_params:
 stats_param
 { 
 $$ = $1;
}
|  stats_params ',' stats_param
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 stats_param:
 ColId
 { 
 $$ = $1;
}
|  func_expr_windowless
 { 
 $$ = $1;
}
|  '(' a_expr ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
;


 AlterStatsStmt:
 ALTER STATISTICS any_name SET STATISTICS SignedIconst
 { 
 $$ = cat_str(4,mm_strdup("alter statistics"),$3,mm_strdup("set statistics"),$6);
}
|  ALTER STATISTICS IF_P EXISTS any_name SET STATISTICS SignedIconst
 { 
 $$ = cat_str(4,mm_strdup("alter statistics if exists"),$5,mm_strdup("set statistics"),$8);
}
;


 create_as_target:
 qualified_name opt_column_list table_access_method_clause OptWith OnCommitOption OptTableSpace
 { 
 $$ = cat_str(6,$1,$2,$3,$4,$5,$6);
}
;


 opt_with_data:
 WITH DATA_P
 { 
 $$ = mm_strdup("with data");
}
|  WITH NO DATA_P
 { 
 $$ = mm_strdup("with no data");
}
| 
 { 
 $$=EMPTY; }
;


 CreateMatViewStmt:
 CREATE OptNoLog MATERIALIZED VIEW create_mv_target AS SelectStmt opt_with_data
 { 
 $$ = cat_str(7,mm_strdup("create"),$2,mm_strdup("materialized view"),$5,mm_strdup("as"),$7,$8);
}
|  CREATE OptNoLog MATERIALIZED VIEW IF_P NOT EXISTS create_mv_target AS SelectStmt opt_with_data
 { 
 $$ = cat_str(7,mm_strdup("create"),$2,mm_strdup("materialized view if not exists"),$8,mm_strdup("as"),$10,$11);
}
;


 create_mv_target:
 qualified_name opt_column_list table_access_method_clause opt_reloptions OptTableSpace
 { 
 $$ = cat_str(5,$1,$2,$3,$4,$5);
}
;


 OptNoLog:
 UNLOGGED
 { 
 $$ = mm_strdup("unlogged");
}
| 
 { 
 $$=EMPTY; }
;


 RefreshMatViewStmt:
 REFRESH MATERIALIZED VIEW opt_concurrently qualified_name opt_with_data
 { 
 $$ = cat_str(4,mm_strdup("refresh materialized view"),$4,$5,$6);
}
;


 CreateSeqStmt:
 CREATE OptTemp SEQUENCE qualified_name OptSeqOptList
 { 
 $$ = cat_str(5,mm_strdup("create"),$2,mm_strdup("sequence"),$4,$5);
}
|  CREATE OptTemp SEQUENCE IF_P NOT EXISTS qualified_name OptSeqOptList
 { 
 $$ = cat_str(5,mm_strdup("create"),$2,mm_strdup("sequence if not exists"),$7,$8);
}
;


 AlterSeqStmt:
 ALTER SEQUENCE qualified_name SeqOptList
 { 
 $$ = cat_str(3,mm_strdup("alter sequence"),$3,$4);
}
|  ALTER SEQUENCE IF_P EXISTS qualified_name SeqOptList
 { 
 $$ = cat_str(3,mm_strdup("alter sequence if exists"),$5,$6);
}
;


 OptSeqOptList:
 SeqOptList
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 OptParenthesizedSeqOptList:
 '(' SeqOptList ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 SeqOptList:
 SeqOptElem
 { 
 $$ = $1;
}
|  SeqOptList SeqOptElem
 { 
 $$ = cat_str(2,$1,$2);
}
;


 SeqOptElem:
 AS SimpleTypename
 { 
 $$ = cat_str(2,mm_strdup("as"),$2);
}
|  CACHE NumericOnly
 { 
 $$ = cat_str(2,mm_strdup("cache"),$2);
}
|  CYCLE
 { 
 $$ = mm_strdup("cycle");
}
|  NO CYCLE
 { 
 $$ = mm_strdup("no cycle");
}
|  INCREMENT opt_by NumericOnly
 { 
 $$ = cat_str(3,mm_strdup("increment"),$2,$3);
}
|  MAXVALUE NumericOnly
 { 
 $$ = cat_str(2,mm_strdup("maxvalue"),$2);
}
|  MINVALUE NumericOnly
 { 
 $$ = cat_str(2,mm_strdup("minvalue"),$2);
}
|  NO MAXVALUE
 { 
 $$ = mm_strdup("no maxvalue");
}
|  NO MINVALUE
 { 
 $$ = mm_strdup("no minvalue");
}
|  OWNED BY any_name
 { 
 $$ = cat_str(2,mm_strdup("owned by"),$3);
}
|  SEQUENCE NAME_P any_name
 { 
 $$ = cat_str(2,mm_strdup("sequence name"),$3);
}
|  START opt_with NumericOnly
 { 
 $$ = cat_str(3,mm_strdup("start"),$2,$3);
}
|  RESTART
 { 
 $$ = mm_strdup("restart");
}
|  RESTART opt_with NumericOnly
 { 
 $$ = cat_str(3,mm_strdup("restart"),$2,$3);
}
;


 opt_by:
 BY
 { 
 $$ = mm_strdup("by");
}
| 
 { 
 $$=EMPTY; }
;


 NumericOnly:
 ecpg_fconst
 { 
 $$ = $1;
}
|  '+' ecpg_fconst
 { 
 $$ = cat_str(2,mm_strdup("+"),$2);
}
|  '-' ecpg_fconst
 { 
 $$ = cat_str(2,mm_strdup("-"),$2);
}
|  SignedIconst
 { 
 $$ = $1;
}
;


 NumericOnly_list:
 NumericOnly
 { 
 $$ = $1;
}
|  NumericOnly_list ',' NumericOnly
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 CreatePLangStmt:
 CREATE opt_or_replace opt_trusted opt_procedural LANGUAGE name
 { 
 $$ = cat_str(6,mm_strdup("create"),$2,$3,$4,mm_strdup("language"),$6);
}
|  CREATE opt_or_replace opt_trusted opt_procedural LANGUAGE name HANDLER handler_name opt_inline_handler opt_validator
 { 
 $$ = cat_str(10,mm_strdup("create"),$2,$3,$4,mm_strdup("language"),$6,mm_strdup("handler"),$8,$9,$10);
}
;


 opt_trusted:
 TRUSTED
 { 
 $$ = mm_strdup("trusted");
}
| 
 { 
 $$=EMPTY; }
;


 handler_name:
 name
 { 
 $$ = $1;
}
|  name attrs
 { 
 $$ = cat_str(2,$1,$2);
}
;


 opt_inline_handler:
 INLINE_P handler_name
 { 
 $$ = cat_str(2,mm_strdup("inline"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 validator_clause:
 VALIDATOR handler_name
 { 
 $$ = cat_str(2,mm_strdup("validator"),$2);
}
|  NO VALIDATOR
 { 
 $$ = mm_strdup("no validator");
}
;


 opt_validator:
 validator_clause
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 opt_procedural:
 PROCEDURAL
 { 
 $$ = mm_strdup("procedural");
}
| 
 { 
 $$=EMPTY; }
;


 CreateTableSpaceStmt:
 CREATE TABLESPACE name OptTableSpaceOwner LOCATION ecpg_sconst opt_reloptions
 { 
 $$ = cat_str(6,mm_strdup("create tablespace"),$3,$4,mm_strdup("location"),$6,$7);
}
;


 OptTableSpaceOwner:
 OWNER RoleSpec
 { 
 $$ = cat_str(2,mm_strdup("owner"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 DropTableSpaceStmt:
 DROP TABLESPACE name
 { 
 $$ = cat_str(2,mm_strdup("drop tablespace"),$3);
}
|  DROP TABLESPACE IF_P EXISTS name
 { 
 $$ = cat_str(2,mm_strdup("drop tablespace if exists"),$5);
}
;


 CreateExtensionStmt:
 CREATE EXTENSION name opt_with create_extension_opt_list
 { 
 $$ = cat_str(4,mm_strdup("create extension"),$3,$4,$5);
}
|  CREATE EXTENSION IF_P NOT EXISTS name opt_with create_extension_opt_list
 { 
 $$ = cat_str(4,mm_strdup("create extension if not exists"),$6,$7,$8);
}
;


 create_extension_opt_list:
 create_extension_opt_list create_extension_opt_item
 { 
 $$ = cat_str(2,$1,$2);
}
| 
 { 
 $$=EMPTY; }
;


 create_extension_opt_item:
 SCHEMA name
 { 
 $$ = cat_str(2,mm_strdup("schema"),$2);
}
|  VERSION_P NonReservedWord_or_Sconst
 { 
 $$ = cat_str(2,mm_strdup("version"),$2);
}
|  FROM NonReservedWord_or_Sconst
 { 
mmerror(PARSE_ERROR, ET_WARNING, "unsupported feature will be passed to server");
 $$ = cat_str(2,mm_strdup("from"),$2);
}
|  CASCADE
 { 
 $$ = mm_strdup("cascade");
}
;


 AlterExtensionStmt:
 ALTER EXTENSION name UPDATE alter_extension_opt_list
 { 
 $$ = cat_str(4,mm_strdup("alter extension"),$3,mm_strdup("update"),$5);
}
;


 alter_extension_opt_list:
 alter_extension_opt_list alter_extension_opt_item
 { 
 $$ = cat_str(2,$1,$2);
}
| 
 { 
 $$=EMPTY; }
;


 alter_extension_opt_item:
 TO NonReservedWord_or_Sconst
 { 
 $$ = cat_str(2,mm_strdup("to"),$2);
}
;


 AlterExtensionContentsStmt:
 ALTER EXTENSION name add_drop object_type_name name
 { 
 $$ = cat_str(5,mm_strdup("alter extension"),$3,$4,$5,$6);
}
|  ALTER EXTENSION name add_drop object_type_any_name any_name
 { 
 $$ = cat_str(5,mm_strdup("alter extension"),$3,$4,$5,$6);
}
|  ALTER EXTENSION name add_drop AGGREGATE aggregate_with_argtypes
 { 
 $$ = cat_str(5,mm_strdup("alter extension"),$3,$4,mm_strdup("aggregate"),$6);
}
|  ALTER EXTENSION name add_drop CAST '(' Typename AS Typename ')'
 { 
 $$ = cat_str(8,mm_strdup("alter extension"),$3,$4,mm_strdup("cast ("),$7,mm_strdup("as"),$9,mm_strdup(")"));
}
|  ALTER EXTENSION name add_drop DOMAIN_P Typename
 { 
 $$ = cat_str(5,mm_strdup("alter extension"),$3,$4,mm_strdup("domain"),$6);
}
|  ALTER EXTENSION name add_drop FUNCTION function_with_argtypes
 { 
 $$ = cat_str(5,mm_strdup("alter extension"),$3,$4,mm_strdup("function"),$6);
}
|  ALTER EXTENSION name add_drop OPERATOR operator_with_argtypes
 { 
 $$ = cat_str(5,mm_strdup("alter extension"),$3,$4,mm_strdup("operator"),$6);
}
|  ALTER EXTENSION name add_drop OPERATOR CLASS any_name USING name
 { 
 $$ = cat_str(7,mm_strdup("alter extension"),$3,$4,mm_strdup("operator class"),$7,mm_strdup("using"),$9);
}
|  ALTER EXTENSION name add_drop OPERATOR FAMILY any_name USING name
 { 
 $$ = cat_str(7,mm_strdup("alter extension"),$3,$4,mm_strdup("operator family"),$7,mm_strdup("using"),$9);
}
|  ALTER EXTENSION name add_drop PROCEDURE function_with_argtypes
 { 
 $$ = cat_str(5,mm_strdup("alter extension"),$3,$4,mm_strdup("procedure"),$6);
}
|  ALTER EXTENSION name add_drop ROUTINE function_with_argtypes
 { 
 $$ = cat_str(5,mm_strdup("alter extension"),$3,$4,mm_strdup("routine"),$6);
}
|  ALTER EXTENSION name add_drop TRANSFORM FOR Typename LANGUAGE name
 { 
 $$ = cat_str(7,mm_strdup("alter extension"),$3,$4,mm_strdup("transform for"),$7,mm_strdup("language"),$9);
}
|  ALTER EXTENSION name add_drop TYPE_P Typename
 { 
 $$ = cat_str(5,mm_strdup("alter extension"),$3,$4,mm_strdup("type"),$6);
}
;


 CreateFdwStmt:
 CREATE FOREIGN DATA_P WRAPPER name opt_fdw_options create_generic_options
 { 
 $$ = cat_str(4,mm_strdup("create foreign data wrapper"),$5,$6,$7);
}
;


 fdw_option:
 HANDLER handler_name
 { 
 $$ = cat_str(2,mm_strdup("handler"),$2);
}
|  NO HANDLER
 { 
 $$ = mm_strdup("no handler");
}
|  VALIDATOR handler_name
 { 
 $$ = cat_str(2,mm_strdup("validator"),$2);
}
|  NO VALIDATOR
 { 
 $$ = mm_strdup("no validator");
}
;


 fdw_options:
 fdw_option
 { 
 $$ = $1;
}
|  fdw_options fdw_option
 { 
 $$ = cat_str(2,$1,$2);
}
;


 opt_fdw_options:
 fdw_options
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 AlterFdwStmt:
 ALTER FOREIGN DATA_P WRAPPER name opt_fdw_options alter_generic_options
 { 
 $$ = cat_str(4,mm_strdup("alter foreign data wrapper"),$5,$6,$7);
}
|  ALTER FOREIGN DATA_P WRAPPER name fdw_options
 { 
 $$ = cat_str(3,mm_strdup("alter foreign data wrapper"),$5,$6);
}
;


 create_generic_options:
 OPTIONS '(' generic_option_list ')'
 { 
 $$ = cat_str(3,mm_strdup("options ("),$3,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 generic_option_list:
 generic_option_elem
 { 
 $$ = $1;
}
|  generic_option_list ',' generic_option_elem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 alter_generic_options:
 OPTIONS '(' alter_generic_option_list ')'
 { 
 $$ = cat_str(3,mm_strdup("options ("),$3,mm_strdup(")"));
}
;


 alter_generic_option_list:
 alter_generic_option_elem
 { 
 $$ = $1;
}
|  alter_generic_option_list ',' alter_generic_option_elem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 alter_generic_option_elem:
 generic_option_elem
 { 
 $$ = $1;
}
|  SET generic_option_elem
 { 
 $$ = cat_str(2,mm_strdup("set"),$2);
}
|  ADD_P generic_option_elem
 { 
 $$ = cat_str(2,mm_strdup("add"),$2);
}
|  DROP generic_option_name
 { 
 $$ = cat_str(2,mm_strdup("drop"),$2);
}
;


 generic_option_elem:
 generic_option_name generic_option_arg
 { 
 $$ = cat_str(2,$1,$2);
}
;


 generic_option_name:
 ColLabel
 { 
 $$ = $1;
}
;


 generic_option_arg:
 ecpg_sconst
 { 
 $$ = $1;
}
;


 CreateForeignServerStmt:
 CREATE SERVER name opt_type opt_foreign_server_version FOREIGN DATA_P WRAPPER name create_generic_options
 { 
 $$ = cat_str(7,mm_strdup("create server"),$3,$4,$5,mm_strdup("foreign data wrapper"),$9,$10);
}
|  CREATE SERVER IF_P NOT EXISTS name opt_type opt_foreign_server_version FOREIGN DATA_P WRAPPER name create_generic_options
 { 
 $$ = cat_str(7,mm_strdup("create server if not exists"),$6,$7,$8,mm_strdup("foreign data wrapper"),$12,$13);
}
;


 opt_type:
 TYPE_P ecpg_sconst
 { 
 $$ = cat_str(2,mm_strdup("type"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 foreign_server_version:
 VERSION_P ecpg_sconst
 { 
 $$ = cat_str(2,mm_strdup("version"),$2);
}
|  VERSION_P NULL_P
 { 
 $$ = mm_strdup("version null");
}
;


 opt_foreign_server_version:
 foreign_server_version
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 AlterForeignServerStmt:
 ALTER SERVER name foreign_server_version alter_generic_options
 { 
 $$ = cat_str(4,mm_strdup("alter server"),$3,$4,$5);
}
|  ALTER SERVER name foreign_server_version
 { 
 $$ = cat_str(3,mm_strdup("alter server"),$3,$4);
}
|  ALTER SERVER name alter_generic_options
 { 
 $$ = cat_str(3,mm_strdup("alter server"),$3,$4);
}
;


 CreateForeignTableStmt:
 CREATE FOREIGN TABLE qualified_name '(' OptTableElementList ')' OptInherit SERVER name create_generic_options
 { 
 $$ = cat_str(9,mm_strdup("create foreign table"),$4,mm_strdup("("),$6,mm_strdup(")"),$8,mm_strdup("server"),$10,$11);
}
|  CREATE FOREIGN TABLE IF_P NOT EXISTS qualified_name '(' OptTableElementList ')' OptInherit SERVER name create_generic_options
 { 
 $$ = cat_str(9,mm_strdup("create foreign table if not exists"),$7,mm_strdup("("),$9,mm_strdup(")"),$11,mm_strdup("server"),$13,$14);
}
|  CREATE FOREIGN TABLE qualified_name PARTITION OF qualified_name OptTypedTableElementList PartitionBoundSpec SERVER name create_generic_options
 { 
 $$ = cat_str(9,mm_strdup("create foreign table"),$4,mm_strdup("partition of"),$7,$8,$9,mm_strdup("server"),$11,$12);
}
|  CREATE FOREIGN TABLE IF_P NOT EXISTS qualified_name PARTITION OF qualified_name OptTypedTableElementList PartitionBoundSpec SERVER name create_generic_options
 { 
 $$ = cat_str(9,mm_strdup("create foreign table if not exists"),$7,mm_strdup("partition of"),$10,$11,$12,mm_strdup("server"),$14,$15);
}
;


 ImportForeignSchemaStmt:
 IMPORT_P FOREIGN SCHEMA name import_qualification FROM SERVER name INTO name create_generic_options
 { 
 $$ = cat_str(8,mm_strdup("import foreign schema"),$4,$5,mm_strdup("from server"),$8,mm_strdup("into"),$10,$11);
}
;


 import_qualification_type:
 LIMIT TO
 { 
 $$ = mm_strdup("limit to");
}
|  EXCEPT
 { 
 $$ = mm_strdup("except");
}
;


 import_qualification:
 import_qualification_type '(' relation_expr_list ')'
 { 
 $$ = cat_str(4,$1,mm_strdup("("),$3,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 CreateUserMappingStmt:
 CREATE USER MAPPING FOR auth_ident SERVER name create_generic_options
 { 
 $$ = cat_str(5,mm_strdup("create user mapping for"),$5,mm_strdup("server"),$7,$8);
}
|  CREATE USER MAPPING IF_P NOT EXISTS FOR auth_ident SERVER name create_generic_options
 { 
 $$ = cat_str(5,mm_strdup("create user mapping if not exists for"),$8,mm_strdup("server"),$10,$11);
}
;


 auth_ident:
 RoleSpec
 { 
 $$ = $1;
}
|  USER
 { 
 $$ = mm_strdup("user");
}
;


 DropUserMappingStmt:
 DROP USER MAPPING FOR auth_ident SERVER name
 { 
 $$ = cat_str(4,mm_strdup("drop user mapping for"),$5,mm_strdup("server"),$7);
}
|  DROP USER MAPPING IF_P EXISTS FOR auth_ident SERVER name
 { 
 $$ = cat_str(4,mm_strdup("drop user mapping if exists for"),$7,mm_strdup("server"),$9);
}
;


 AlterUserMappingStmt:
 ALTER USER MAPPING FOR auth_ident SERVER name alter_generic_options
 { 
 $$ = cat_str(5,mm_strdup("alter user mapping for"),$5,mm_strdup("server"),$7,$8);
}
;


 CreatePolicyStmt:
 CREATE POLICY name ON qualified_name RowSecurityDefaultPermissive RowSecurityDefaultForCmd RowSecurityDefaultToRole RowSecurityOptionalExpr RowSecurityOptionalWithCheck
 { 
 $$ = cat_str(9,mm_strdup("create policy"),$3,mm_strdup("on"),$5,$6,$7,$8,$9,$10);
}
;


 AlterPolicyStmt:
 ALTER POLICY name ON qualified_name RowSecurityOptionalToRole RowSecurityOptionalExpr RowSecurityOptionalWithCheck
 { 
 $$ = cat_str(7,mm_strdup("alter policy"),$3,mm_strdup("on"),$5,$6,$7,$8);
}
;


 RowSecurityOptionalExpr:
 USING '(' a_expr ')'
 { 
 $$ = cat_str(3,mm_strdup("using ("),$3,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 RowSecurityOptionalWithCheck:
 WITH CHECK '(' a_expr ')'
 { 
 $$ = cat_str(3,mm_strdup("with check ("),$4,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 RowSecurityDefaultToRole:
 TO role_list
 { 
 $$ = cat_str(2,mm_strdup("to"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 RowSecurityOptionalToRole:
 TO role_list
 { 
 $$ = cat_str(2,mm_strdup("to"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 RowSecurityDefaultPermissive:
 AS ecpg_ident
 { 
 $$ = cat_str(2,mm_strdup("as"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 RowSecurityDefaultForCmd:
 FOR row_security_cmd
 { 
 $$ = cat_str(2,mm_strdup("for"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 row_security_cmd:
 ALL
 { 
 $$ = mm_strdup("all");
}
|  SELECT
 { 
 $$ = mm_strdup("select");
}
|  INSERT
 { 
 $$ = mm_strdup("insert");
}
|  UPDATE
 { 
 $$ = mm_strdup("update");
}
|  DELETE_P
 { 
 $$ = mm_strdup("delete");
}
;


 CreateAmStmt:
 CREATE ACCESS METHOD name TYPE_P am_type HANDLER handler_name
 { 
 $$ = cat_str(6,mm_strdup("create access method"),$4,mm_strdup("type"),$6,mm_strdup("handler"),$8);
}
;


 am_type:
 INDEX
 { 
 $$ = mm_strdup("index");
}
|  TABLE
 { 
 $$ = mm_strdup("table");
}
;


 CreateTrigStmt:
 CREATE opt_or_replace TRIGGER name TriggerActionTime TriggerEvents ON qualified_name TriggerReferencing TriggerForSpec TriggerWhen EXECUTE FUNCTION_or_PROCEDURE func_name '(' TriggerFuncArgs ')'
 { 
 $$ = cat_str(17,mm_strdup("create"),$2,mm_strdup("trigger"),$4,$5,$6,mm_strdup("on"),$8,$9,$10,$11,mm_strdup("execute"),$13,$14,mm_strdup("("),$16,mm_strdup(")"));
}
|  CREATE opt_or_replace CONSTRAINT TRIGGER name AFTER TriggerEvents ON qualified_name OptConstrFromTable ConstraintAttributeSpec FOR EACH ROW TriggerWhen EXECUTE FUNCTION_or_PROCEDURE func_name '(' TriggerFuncArgs ')'
 { 
 $$ = cat_str(18,mm_strdup("create"),$2,mm_strdup("constraint trigger"),$5,mm_strdup("after"),$7,mm_strdup("on"),$9,$10,$11,mm_strdup("for each row"),$15,mm_strdup("execute"),$17,$18,mm_strdup("("),$20,mm_strdup(")"));
}
;


 TriggerActionTime:
 BEFORE
 { 
 $$ = mm_strdup("before");
}
|  AFTER
 { 
 $$ = mm_strdup("after");
}
|  INSTEAD OF
 { 
 $$ = mm_strdup("instead of");
}
;


 TriggerEvents:
 TriggerOneEvent
 { 
 $$ = $1;
}
|  TriggerEvents OR TriggerOneEvent
 { 
 $$ = cat_str(3,$1,mm_strdup("or"),$3);
}
;


 TriggerOneEvent:
 INSERT
 { 
 $$ = mm_strdup("insert");
}
|  DELETE_P
 { 
 $$ = mm_strdup("delete");
}
|  UPDATE
 { 
 $$ = mm_strdup("update");
}
|  UPDATE OF columnList
 { 
 $$ = cat_str(2,mm_strdup("update of"),$3);
}
|  TRUNCATE
 { 
 $$ = mm_strdup("truncate");
}
;


 TriggerReferencing:
 REFERENCING TriggerTransitions
 { 
 $$ = cat_str(2,mm_strdup("referencing"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 TriggerTransitions:
 TriggerTransition
 { 
 $$ = $1;
}
|  TriggerTransitions TriggerTransition
 { 
 $$ = cat_str(2,$1,$2);
}
;


 TriggerTransition:
 TransitionOldOrNew TransitionRowOrTable opt_as TransitionRelName
 { 
 $$ = cat_str(4,$1,$2,$3,$4);
}
;


 TransitionOldOrNew:
 NEW
 { 
 $$ = mm_strdup("new");
}
|  OLD
 { 
 $$ = mm_strdup("old");
}
;


 TransitionRowOrTable:
 TABLE
 { 
 $$ = mm_strdup("table");
}
|  ROW
 { 
 $$ = mm_strdup("row");
}
;


 TransitionRelName:
 ColId
 { 
 $$ = $1;
}
;


 TriggerForSpec:
 FOR TriggerForOptEach TriggerForType
 { 
 $$ = cat_str(3,mm_strdup("for"),$2,$3);
}
| 
 { 
 $$=EMPTY; }
;


 TriggerForOptEach:
 EACH
 { 
 $$ = mm_strdup("each");
}
| 
 { 
 $$=EMPTY; }
;


 TriggerForType:
 ROW
 { 
 $$ = mm_strdup("row");
}
|  STATEMENT
 { 
 $$ = mm_strdup("statement");
}
;


 TriggerWhen:
 WHEN '(' a_expr ')'
 { 
 $$ = cat_str(3,mm_strdup("when ("),$3,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 FUNCTION_or_PROCEDURE:
 FUNCTION
 { 
 $$ = mm_strdup("function");
}
|  PROCEDURE
 { 
 $$ = mm_strdup("procedure");
}
;


 TriggerFuncArgs:
 TriggerFuncArg
 { 
 $$ = $1;
}
|  TriggerFuncArgs ',' TriggerFuncArg
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
| 
 { 
 $$=EMPTY; }
;


 TriggerFuncArg:
 Iconst
 { 
 $$ = $1;
}
|  ecpg_fconst
 { 
 $$ = $1;
}
|  ecpg_sconst
 { 
 $$ = $1;
}
|  ColLabel
 { 
 $$ = $1;
}
;


 OptConstrFromTable:
 FROM qualified_name
 { 
 $$ = cat_str(2,mm_strdup("from"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 ConstraintAttributeSpec:

 { 
 $$=EMPTY; }
|  ConstraintAttributeSpec ConstraintAttributeElem
 { 
 $$ = cat_str(2,$1,$2);
}
;


 ConstraintAttributeElem:
 NOT DEFERRABLE
 { 
 $$ = mm_strdup("not deferrable");
}
|  DEFERRABLE
 { 
 $$ = mm_strdup("deferrable");
}
|  INITIALLY IMMEDIATE
 { 
 $$ = mm_strdup("initially immediate");
}
|  INITIALLY DEFERRED
 { 
 $$ = mm_strdup("initially deferred");
}
|  NOT VALID
 { 
 $$ = mm_strdup("not valid");
}
|  NO INHERIT
 { 
 $$ = mm_strdup("no inherit");
}
;


 CreateEventTrigStmt:
 CREATE EVENT TRIGGER name ON ColLabel EXECUTE FUNCTION_or_PROCEDURE func_name '(' ')'
 { 
 $$ = cat_str(8,mm_strdup("create event trigger"),$4,mm_strdup("on"),$6,mm_strdup("execute"),$8,$9,mm_strdup("( )"));
}
|  CREATE EVENT TRIGGER name ON ColLabel WHEN event_trigger_when_list EXECUTE FUNCTION_or_PROCEDURE func_name '(' ')'
 { 
 $$ = cat_str(10,mm_strdup("create event trigger"),$4,mm_strdup("on"),$6,mm_strdup("when"),$8,mm_strdup("execute"),$10,$11,mm_strdup("( )"));
}
;


 event_trigger_when_list:
 event_trigger_when_item
 { 
 $$ = $1;
}
|  event_trigger_when_list AND event_trigger_when_item
 { 
 $$ = cat_str(3,$1,mm_strdup("and"),$3);
}
;


 event_trigger_when_item:
 ColId IN_P '(' event_trigger_value_list ')'
 { 
 $$ = cat_str(4,$1,mm_strdup("in ("),$4,mm_strdup(")"));
}
;


 event_trigger_value_list:
 SCONST
 { 
 $$ = mm_strdup("sconst");
}
|  event_trigger_value_list ',' SCONST
 { 
 $$ = cat_str(2,$1,mm_strdup(", sconst"));
}
;


 AlterEventTrigStmt:
 ALTER EVENT TRIGGER name enable_trigger
 { 
 $$ = cat_str(3,mm_strdup("alter event trigger"),$4,$5);
}
;


 enable_trigger:
 ENABLE_P
 { 
 $$ = mm_strdup("enable");
}
|  ENABLE_P REPLICA
 { 
 $$ = mm_strdup("enable replica");
}
|  ENABLE_P ALWAYS
 { 
 $$ = mm_strdup("enable always");
}
|  DISABLE_P
 { 
 $$ = mm_strdup("disable");
}
;


 CreateAssertionStmt:
 CREATE ASSERTION any_name CHECK '(' a_expr ')' ConstraintAttributeSpec
 { 
mmerror(PARSE_ERROR, ET_WARNING, "unsupported feature will be passed to server");
 $$ = cat_str(6,mm_strdup("create assertion"),$3,mm_strdup("check ("),$6,mm_strdup(")"),$8);
}
;


 DefineStmt:
 CREATE opt_or_replace AGGREGATE func_name aggr_args definition
 { 
 $$ = cat_str(6,mm_strdup("create"),$2,mm_strdup("aggregate"),$4,$5,$6);
}
|  CREATE opt_or_replace AGGREGATE func_name old_aggr_definition
 { 
 $$ = cat_str(5,mm_strdup("create"),$2,mm_strdup("aggregate"),$4,$5);
}
|  CREATE OPERATOR any_operator definition
 { 
 $$ = cat_str(3,mm_strdup("create operator"),$3,$4);
}
|  CREATE TYPE_P any_name definition
 { 
 $$ = cat_str(3,mm_strdup("create type"),$3,$4);
}
|  CREATE TYPE_P any_name
 { 
 $$ = cat_str(2,mm_strdup("create type"),$3);
}
|  CREATE TYPE_P any_name AS '(' OptTableFuncElementList ')'
 { 
 $$ = cat_str(5,mm_strdup("create type"),$3,mm_strdup("as ("),$6,mm_strdup(")"));
}
|  CREATE TYPE_P any_name AS ENUM_P '(' opt_enum_val_list ')'
 { 
 $$ = cat_str(5,mm_strdup("create type"),$3,mm_strdup("as enum ("),$7,mm_strdup(")"));
}
|  CREATE TYPE_P any_name AS RANGE definition
 { 
 $$ = cat_str(4,mm_strdup("create type"),$3,mm_strdup("as range"),$6);
}
|  CREATE TEXT_P SEARCH PARSER any_name definition
 { 
 $$ = cat_str(3,mm_strdup("create text search parser"),$5,$6);
}
|  CREATE TEXT_P SEARCH DICTIONARY any_name definition
 { 
 $$ = cat_str(3,mm_strdup("create text search dictionary"),$5,$6);
}
|  CREATE TEXT_P SEARCH TEMPLATE any_name definition
 { 
 $$ = cat_str(3,mm_strdup("create text search template"),$5,$6);
}
|  CREATE TEXT_P SEARCH CONFIGURATION any_name definition
 { 
 $$ = cat_str(3,mm_strdup("create text search configuration"),$5,$6);
}
|  CREATE COLLATION any_name definition
 { 
 $$ = cat_str(3,mm_strdup("create collation"),$3,$4);
}
|  CREATE COLLATION IF_P NOT EXISTS any_name definition
 { 
 $$ = cat_str(3,mm_strdup("create collation if not exists"),$6,$7);
}
|  CREATE COLLATION any_name FROM any_name
 { 
 $$ = cat_str(4,mm_strdup("create collation"),$3,mm_strdup("from"),$5);
}
|  CREATE COLLATION IF_P NOT EXISTS any_name FROM any_name
 { 
 $$ = cat_str(4,mm_strdup("create collation if not exists"),$6,mm_strdup("from"),$8);
}
;


 definition:
 '(' def_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
;


 def_list:
 def_elem
 { 
 $$ = $1;
}
|  def_list ',' def_elem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 def_elem:
 ColLabel '=' def_arg
 { 
 $$ = cat_str(3,$1,mm_strdup("="),$3);
}
|  ColLabel
 { 
 $$ = $1;
}
;


 def_arg:
 func_type
 { 
 $$ = $1;
}
|  reserved_keyword
 { 
 $$ = $1;
}
|  qual_all_Op
 { 
 $$ = $1;
}
|  NumericOnly
 { 
 $$ = $1;
}
|  ecpg_sconst
 { 
 $$ = $1;
}
|  NONE
 { 
 $$ = mm_strdup("none");
}
;


 old_aggr_definition:
 '(' old_aggr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
;


 old_aggr_list:
 old_aggr_elem
 { 
 $$ = $1;
}
|  old_aggr_list ',' old_aggr_elem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 old_aggr_elem:
 ecpg_ident '=' def_arg
 { 
 $$ = cat_str(3,$1,mm_strdup("="),$3);
}
;


 opt_enum_val_list:
 enum_val_list
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 enum_val_list:
 ecpg_sconst
 { 
 $$ = $1;
}
|  enum_val_list ',' ecpg_sconst
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 AlterEnumStmt:
 ALTER TYPE_P any_name ADD_P VALUE_P opt_if_not_exists ecpg_sconst
 { 
 $$ = cat_str(5,mm_strdup("alter type"),$3,mm_strdup("add value"),$6,$7);
}
|  ALTER TYPE_P any_name ADD_P VALUE_P opt_if_not_exists ecpg_sconst BEFORE ecpg_sconst
 { 
 $$ = cat_str(7,mm_strdup("alter type"),$3,mm_strdup("add value"),$6,$7,mm_strdup("before"),$9);
}
|  ALTER TYPE_P any_name ADD_P VALUE_P opt_if_not_exists ecpg_sconst AFTER ecpg_sconst
 { 
 $$ = cat_str(7,mm_strdup("alter type"),$3,mm_strdup("add value"),$6,$7,mm_strdup("after"),$9);
}
|  ALTER TYPE_P any_name RENAME VALUE_P ecpg_sconst TO ecpg_sconst
 { 
 $$ = cat_str(6,mm_strdup("alter type"),$3,mm_strdup("rename value"),$6,mm_strdup("to"),$8);
}
;


 opt_if_not_exists:
 IF_P NOT EXISTS
 { 
 $$ = mm_strdup("if not exists");
}
| 
 { 
 $$=EMPTY; }
;


 CreateOpClassStmt:
 CREATE OPERATOR CLASS any_name opt_default FOR TYPE_P Typename USING name opt_opfamily AS opclass_item_list
 { 
 $$ = cat_str(10,mm_strdup("create operator class"),$4,$5,mm_strdup("for type"),$8,mm_strdup("using"),$10,$11,mm_strdup("as"),$13);
}
;


 opclass_item_list:
 opclass_item
 { 
 $$ = $1;
}
|  opclass_item_list ',' opclass_item
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 opclass_item:
 OPERATOR Iconst any_operator opclass_purpose opt_recheck
 { 
 $$ = cat_str(5,mm_strdup("operator"),$2,$3,$4,$5);
}
|  OPERATOR Iconst operator_with_argtypes opclass_purpose opt_recheck
 { 
 $$ = cat_str(5,mm_strdup("operator"),$2,$3,$4,$5);
}
|  FUNCTION Iconst function_with_argtypes
 { 
 $$ = cat_str(3,mm_strdup("function"),$2,$3);
}
|  FUNCTION Iconst '(' type_list ')' function_with_argtypes
 { 
 $$ = cat_str(6,mm_strdup("function"),$2,mm_strdup("("),$4,mm_strdup(")"),$6);
}
|  STORAGE Typename
 { 
 $$ = cat_str(2,mm_strdup("storage"),$2);
}
;


 opt_default:
 DEFAULT
 { 
 $$ = mm_strdup("default");
}
| 
 { 
 $$=EMPTY; }
;


 opt_opfamily:
 FAMILY any_name
 { 
 $$ = cat_str(2,mm_strdup("family"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 opclass_purpose:
 FOR SEARCH
 { 
 $$ = mm_strdup("for search");
}
|  FOR ORDER BY any_name
 { 
 $$ = cat_str(2,mm_strdup("for order by"),$4);
}
| 
 { 
 $$=EMPTY; }
;


 opt_recheck:
 RECHECK
 { 
mmerror(PARSE_ERROR, ET_WARNING, "unsupported feature will be passed to server");
 $$ = mm_strdup("recheck");
}
| 
 { 
 $$=EMPTY; }
;


 CreateOpFamilyStmt:
 CREATE OPERATOR FAMILY any_name USING name
 { 
 $$ = cat_str(4,mm_strdup("create operator family"),$4,mm_strdup("using"),$6);
}
;


 AlterOpFamilyStmt:
 ALTER OPERATOR FAMILY any_name USING name ADD_P opclass_item_list
 { 
 $$ = cat_str(6,mm_strdup("alter operator family"),$4,mm_strdup("using"),$6,mm_strdup("add"),$8);
}
|  ALTER OPERATOR FAMILY any_name USING name DROP opclass_drop_list
 { 
 $$ = cat_str(6,mm_strdup("alter operator family"),$4,mm_strdup("using"),$6,mm_strdup("drop"),$8);
}
;


 opclass_drop_list:
 opclass_drop
 { 
 $$ = $1;
}
|  opclass_drop_list ',' opclass_drop
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 opclass_drop:
 OPERATOR Iconst '(' type_list ')'
 { 
 $$ = cat_str(5,mm_strdup("operator"),$2,mm_strdup("("),$4,mm_strdup(")"));
}
|  FUNCTION Iconst '(' type_list ')'
 { 
 $$ = cat_str(5,mm_strdup("function"),$2,mm_strdup("("),$4,mm_strdup(")"));
}
;


 DropOpClassStmt:
 DROP OPERATOR CLASS any_name USING name opt_drop_behavior
 { 
 $$ = cat_str(5,mm_strdup("drop operator class"),$4,mm_strdup("using"),$6,$7);
}
|  DROP OPERATOR CLASS IF_P EXISTS any_name USING name opt_drop_behavior
 { 
 $$ = cat_str(5,mm_strdup("drop operator class if exists"),$6,mm_strdup("using"),$8,$9);
}
;


 DropOpFamilyStmt:
 DROP OPERATOR FAMILY any_name USING name opt_drop_behavior
 { 
 $$ = cat_str(5,mm_strdup("drop operator family"),$4,mm_strdup("using"),$6,$7);
}
|  DROP OPERATOR FAMILY IF_P EXISTS any_name USING name opt_drop_behavior
 { 
 $$ = cat_str(5,mm_strdup("drop operator family if exists"),$6,mm_strdup("using"),$8,$9);
}
;


 DropOwnedStmt:
 DROP OWNED BY role_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop owned by"),$4,$5);
}
;


 ReassignOwnedStmt:
 REASSIGN OWNED BY role_list TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("reassign owned by"),$4,mm_strdup("to"),$6);
}
;


 DropStmt:
 DROP object_type_any_name IF_P EXISTS any_name_list opt_drop_behavior
 { 
 $$ = cat_str(5,mm_strdup("drop"),$2,mm_strdup("if exists"),$5,$6);
}
|  DROP object_type_any_name any_name_list opt_drop_behavior
 { 
 $$ = cat_str(4,mm_strdup("drop"),$2,$3,$4);
}
|  DROP drop_type_name IF_P EXISTS name_list opt_drop_behavior
 { 
 $$ = cat_str(5,mm_strdup("drop"),$2,mm_strdup("if exists"),$5,$6);
}
|  DROP drop_type_name name_list opt_drop_behavior
 { 
 $$ = cat_str(4,mm_strdup("drop"),$2,$3,$4);
}
|  DROP object_type_name_on_any_name name ON any_name opt_drop_behavior
 { 
 $$ = cat_str(6,mm_strdup("drop"),$2,$3,mm_strdup("on"),$5,$6);
}
|  DROP object_type_name_on_any_name IF_P EXISTS name ON any_name opt_drop_behavior
 { 
 $$ = cat_str(7,mm_strdup("drop"),$2,mm_strdup("if exists"),$5,mm_strdup("on"),$7,$8);
}
|  DROP TYPE_P type_name_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop type"),$3,$4);
}
|  DROP TYPE_P IF_P EXISTS type_name_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop type if exists"),$5,$6);
}
|  DROP DOMAIN_P type_name_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop domain"),$3,$4);
}
|  DROP DOMAIN_P IF_P EXISTS type_name_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop domain if exists"),$5,$6);
}
|  DROP INDEX CONCURRENTLY any_name_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop index concurrently"),$4,$5);
}
|  DROP INDEX CONCURRENTLY IF_P EXISTS any_name_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop index concurrently if exists"),$6,$7);
}
;


 object_type_any_name:
 TABLE
 { 
 $$ = mm_strdup("table");
}
|  SEQUENCE
 { 
 $$ = mm_strdup("sequence");
}
|  VIEW
 { 
 $$ = mm_strdup("view");
}
|  MATERIALIZED VIEW
 { 
 $$ = mm_strdup("materialized view");
}
|  INDEX
 { 
 $$ = mm_strdup("index");
}
|  FOREIGN TABLE
 { 
 $$ = mm_strdup("foreign table");
}
|  COLLATION
 { 
 $$ = mm_strdup("collation");
}
|  CONVERSION_P
 { 
 $$ = mm_strdup("conversion");
}
|  STATISTICS
 { 
 $$ = mm_strdup("statistics");
}
|  TEXT_P SEARCH PARSER
 { 
 $$ = mm_strdup("text search parser");
}
|  TEXT_P SEARCH DICTIONARY
 { 
 $$ = mm_strdup("text search dictionary");
}
|  TEXT_P SEARCH TEMPLATE
 { 
 $$ = mm_strdup("text search template");
}
|  TEXT_P SEARCH CONFIGURATION
 { 
 $$ = mm_strdup("text search configuration");
}
;


 object_type_name:
 drop_type_name
 { 
 $$ = $1;
}
|  DATABASE
 { 
 $$ = mm_strdup("database");
}
|  ROLE
 { 
 $$ = mm_strdup("role");
}
|  SUBSCRIPTION
 { 
 $$ = mm_strdup("subscription");
}
|  TABLESPACE
 { 
 $$ = mm_strdup("tablespace");
}
;


 drop_type_name:
 ACCESS METHOD
 { 
 $$ = mm_strdup("access method");
}
|  EVENT TRIGGER
 { 
 $$ = mm_strdup("event trigger");
}
|  EXTENSION
 { 
 $$ = mm_strdup("extension");
}
|  FOREIGN DATA_P WRAPPER
 { 
 $$ = mm_strdup("foreign data wrapper");
}
|  opt_procedural LANGUAGE
 { 
 $$ = cat_str(2,$1,mm_strdup("language"));
}
|  PUBLICATION
 { 
 $$ = mm_strdup("publication");
}
|  SCHEMA
 { 
 $$ = mm_strdup("schema");
}
|  SERVER
 { 
 $$ = mm_strdup("server");
}
;


 object_type_name_on_any_name:
 POLICY
 { 
 $$ = mm_strdup("policy");
}
|  RULE
 { 
 $$ = mm_strdup("rule");
}
|  TRIGGER
 { 
 $$ = mm_strdup("trigger");
}
;


 any_name_list:
 any_name
 { 
 $$ = $1;
}
|  any_name_list ',' any_name
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 any_name:
 ColId
 { 
 $$ = $1;
}
|  ColId attrs
 { 
 $$ = cat_str(2,$1,$2);
}
;


 attrs:
 '.' attr_name
 { 
 $$ = cat_str(2,mm_strdup("."),$2);
}
|  attrs '.' attr_name
 { 
 $$ = cat_str(3,$1,mm_strdup("."),$3);
}
;


 type_name_list:
 Typename
 { 
 $$ = $1;
}
|  type_name_list ',' Typename
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 TruncateStmt:
 TRUNCATE opt_table relation_expr_list opt_restart_seqs opt_drop_behavior
 { 
 $$ = cat_str(5,mm_strdup("truncate"),$2,$3,$4,$5);
}
;


 opt_restart_seqs:
 CONTINUE_P IDENTITY_P
 { 
 $$ = mm_strdup("continue identity");
}
|  RESTART IDENTITY_P
 { 
 $$ = mm_strdup("restart identity");
}
| 
 { 
 $$=EMPTY; }
;


 CommentStmt:
 COMMENT ON object_type_any_name any_name IS comment_text
 { 
 $$ = cat_str(5,mm_strdup("comment on"),$3,$4,mm_strdup("is"),$6);
}
|  COMMENT ON COLUMN any_name IS comment_text
 { 
 $$ = cat_str(4,mm_strdup("comment on column"),$4,mm_strdup("is"),$6);
}
|  COMMENT ON object_type_name name IS comment_text
 { 
 $$ = cat_str(5,mm_strdup("comment on"),$3,$4,mm_strdup("is"),$6);
}
|  COMMENT ON TYPE_P Typename IS comment_text
 { 
 $$ = cat_str(4,mm_strdup("comment on type"),$4,mm_strdup("is"),$6);
}
|  COMMENT ON DOMAIN_P Typename IS comment_text
 { 
 $$ = cat_str(4,mm_strdup("comment on domain"),$4,mm_strdup("is"),$6);
}
|  COMMENT ON AGGREGATE aggregate_with_argtypes IS comment_text
 { 
 $$ = cat_str(4,mm_strdup("comment on aggregate"),$4,mm_strdup("is"),$6);
}
|  COMMENT ON FUNCTION function_with_argtypes IS comment_text
 { 
 $$ = cat_str(4,mm_strdup("comment on function"),$4,mm_strdup("is"),$6);
}
|  COMMENT ON OPERATOR operator_with_argtypes IS comment_text
 { 
 $$ = cat_str(4,mm_strdup("comment on operator"),$4,mm_strdup("is"),$6);
}
|  COMMENT ON CONSTRAINT name ON any_name IS comment_text
 { 
 $$ = cat_str(6,mm_strdup("comment on constraint"),$4,mm_strdup("on"),$6,mm_strdup("is"),$8);
}
|  COMMENT ON CONSTRAINT name ON DOMAIN_P any_name IS comment_text
 { 
 $$ = cat_str(6,mm_strdup("comment on constraint"),$4,mm_strdup("on domain"),$7,mm_strdup("is"),$9);
}
|  COMMENT ON object_type_name_on_any_name name ON any_name IS comment_text
 { 
 $$ = cat_str(7,mm_strdup("comment on"),$3,$4,mm_strdup("on"),$6,mm_strdup("is"),$8);
}
|  COMMENT ON PROCEDURE function_with_argtypes IS comment_text
 { 
 $$ = cat_str(4,mm_strdup("comment on procedure"),$4,mm_strdup("is"),$6);
}
|  COMMENT ON ROUTINE function_with_argtypes IS comment_text
 { 
 $$ = cat_str(4,mm_strdup("comment on routine"),$4,mm_strdup("is"),$6);
}
|  COMMENT ON TRANSFORM FOR Typename LANGUAGE name IS comment_text
 { 
 $$ = cat_str(6,mm_strdup("comment on transform for"),$5,mm_strdup("language"),$7,mm_strdup("is"),$9);
}
|  COMMENT ON OPERATOR CLASS any_name USING name IS comment_text
 { 
 $$ = cat_str(6,mm_strdup("comment on operator class"),$5,mm_strdup("using"),$7,mm_strdup("is"),$9);
}
|  COMMENT ON OPERATOR FAMILY any_name USING name IS comment_text
 { 
 $$ = cat_str(6,mm_strdup("comment on operator family"),$5,mm_strdup("using"),$7,mm_strdup("is"),$9);
}
|  COMMENT ON LARGE_P OBJECT_P NumericOnly IS comment_text
 { 
 $$ = cat_str(4,mm_strdup("comment on large object"),$5,mm_strdup("is"),$7);
}
|  COMMENT ON CAST '(' Typename AS Typename ')' IS comment_text
 { 
 $$ = cat_str(6,mm_strdup("comment on cast ("),$5,mm_strdup("as"),$7,mm_strdup(") is"),$10);
}
;


 comment_text:
 ecpg_sconst
 { 
 $$ = $1;
}
|  NULL_P
 { 
 $$ = mm_strdup("null");
}
;


 SecLabelStmt:
 SECURITY LABEL opt_provider ON object_type_any_name any_name IS security_label
 { 
 $$ = cat_str(7,mm_strdup("security label"),$3,mm_strdup("on"),$5,$6,mm_strdup("is"),$8);
}
|  SECURITY LABEL opt_provider ON COLUMN any_name IS security_label
 { 
 $$ = cat_str(6,mm_strdup("security label"),$3,mm_strdup("on column"),$6,mm_strdup("is"),$8);
}
|  SECURITY LABEL opt_provider ON object_type_name name IS security_label
 { 
 $$ = cat_str(7,mm_strdup("security label"),$3,mm_strdup("on"),$5,$6,mm_strdup("is"),$8);
}
|  SECURITY LABEL opt_provider ON TYPE_P Typename IS security_label
 { 
 $$ = cat_str(6,mm_strdup("security label"),$3,mm_strdup("on type"),$6,mm_strdup("is"),$8);
}
|  SECURITY LABEL opt_provider ON DOMAIN_P Typename IS security_label
 { 
 $$ = cat_str(6,mm_strdup("security label"),$3,mm_strdup("on domain"),$6,mm_strdup("is"),$8);
}
|  SECURITY LABEL opt_provider ON AGGREGATE aggregate_with_argtypes IS security_label
 { 
 $$ = cat_str(6,mm_strdup("security label"),$3,mm_strdup("on aggregate"),$6,mm_strdup("is"),$8);
}
|  SECURITY LABEL opt_provider ON FUNCTION function_with_argtypes IS security_label
 { 
 $$ = cat_str(6,mm_strdup("security label"),$3,mm_strdup("on function"),$6,mm_strdup("is"),$8);
}
|  SECURITY LABEL opt_provider ON LARGE_P OBJECT_P NumericOnly IS security_label
 { 
 $$ = cat_str(6,mm_strdup("security label"),$3,mm_strdup("on large object"),$7,mm_strdup("is"),$9);
}
|  SECURITY LABEL opt_provider ON PROCEDURE function_with_argtypes IS security_label
 { 
 $$ = cat_str(6,mm_strdup("security label"),$3,mm_strdup("on procedure"),$6,mm_strdup("is"),$8);
}
|  SECURITY LABEL opt_provider ON ROUTINE function_with_argtypes IS security_label
 { 
 $$ = cat_str(6,mm_strdup("security label"),$3,mm_strdup("on routine"),$6,mm_strdup("is"),$8);
}
;


 opt_provider:
 FOR NonReservedWord_or_Sconst
 { 
 $$ = cat_str(2,mm_strdup("for"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 security_label:
 ecpg_sconst
 { 
 $$ = $1;
}
|  NULL_P
 { 
 $$ = mm_strdup("null");
}
;


 FetchStmt:
 FETCH fetch_args
 { 
 $$ = cat_str(2,mm_strdup("fetch"),$2);
}
|  MOVE fetch_args
 { 
 $$ = cat_str(2,mm_strdup("move"),$2);
}
	| FETCH fetch_args ecpg_fetch_into
	{
		$$ = cat2_str(mm_strdup("fetch"), $2);
	}
	| FETCH FORWARD cursor_name opt_ecpg_fetch_into
	{
		char *cursor_marker = $3[0] == ':' ? mm_strdup("$0") : $3;
		struct cursor *ptr = add_additional_variables($3, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		$$ = cat_str(2, mm_strdup("fetch forward"), cursor_marker);
	}
	| FETCH FORWARD from_in cursor_name opt_ecpg_fetch_into
	{
		char *cursor_marker = $4[0] == ':' ? mm_strdup("$0") : $4;
		struct cursor *ptr = add_additional_variables($4, false);
			if (ptr -> connection)
				connection = mm_strdup(ptr -> connection);

		$$ = cat_str(2, mm_strdup("fetch forward from"), cursor_marker);
	}
	| FETCH BACKWARD cursor_name opt_ecpg_fetch_into
	{
		char *cursor_marker = $3[0] == ':' ? mm_strdup("$0") : $3;
		struct cursor *ptr = add_additional_variables($3, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		$$ = cat_str(2, mm_strdup("fetch backward"), cursor_marker);
	}
	| FETCH BACKWARD from_in cursor_name opt_ecpg_fetch_into
	{
		char *cursor_marker = $4[0] == ':' ? mm_strdup("$0") : $4;
		struct cursor *ptr = add_additional_variables($4, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		$$ = cat_str(2, mm_strdup("fetch backward from"), cursor_marker);
	}
	| MOVE FORWARD cursor_name
	{
		char *cursor_marker = $3[0] == ':' ? mm_strdup("$0") : $3;
		struct cursor *ptr = add_additional_variables($3, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		$$ = cat_str(2, mm_strdup("move forward"), cursor_marker);
	}
	| MOVE FORWARD from_in cursor_name
	{
		char *cursor_marker = $4[0] == ':' ? mm_strdup("$0") : $4;
		struct cursor *ptr = add_additional_variables($4, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		$$ = cat_str(2, mm_strdup("move forward from"), cursor_marker);
	}
	| MOVE BACKWARD cursor_name
	{
		char *cursor_marker = $3[0] == ':' ? mm_strdup("$0") : $3;
		struct cursor *ptr = add_additional_variables($3, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		$$ = cat_str(2, mm_strdup("move backward"), cursor_marker);
	}
	| MOVE BACKWARD from_in cursor_name
	{
		char *cursor_marker = $4[0] == ':' ? mm_strdup("$0") : $4;
		struct cursor *ptr = add_additional_variables($4, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		$$ = cat_str(2, mm_strdup("move backward from"), cursor_marker);
	}
;


 fetch_args:
 cursor_name
 { 
		struct cursor *ptr = add_additional_variables($1, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($1[0] == ':')
		{
			free($1);
			$1 = mm_strdup("$0");
		}

 $$ = $1;
}
|  from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($2, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($2[0] == ':')
		{
			free($2);
			$2 = mm_strdup("$0");
		}

 $$ = cat_str(2,$1,$2);
}
|  NEXT opt_from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($3, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($3[0] == ':')
		{
			free($3);
			$3 = mm_strdup("$0");
		}

 $$ = cat_str(3,mm_strdup("next"),$2,$3);
}
|  PRIOR opt_from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($3, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($3[0] == ':')
		{
			free($3);
			$3 = mm_strdup("$0");
		}

 $$ = cat_str(3,mm_strdup("prior"),$2,$3);
}
|  FIRST_P opt_from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($3, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($3[0] == ':')
		{
			free($3);
			$3 = mm_strdup("$0");
		}

 $$ = cat_str(3,mm_strdup("first"),$2,$3);
}
|  LAST_P opt_from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($3, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($3[0] == ':')
		{
			free($3);
			$3 = mm_strdup("$0");
		}

 $$ = cat_str(3,mm_strdup("last"),$2,$3);
}
|  ABSOLUTE_P SignedIconst opt_from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($4, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($4[0] == ':')
		{
			free($4);
			$4 = mm_strdup("$0");
		}
		if ($2[0] == '$')
		{
			free($2);
			$2 = mm_strdup("$0");
		}

 $$ = cat_str(4,mm_strdup("absolute"),$2,$3,$4);
}
|  RELATIVE_P SignedIconst opt_from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($4, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($4[0] == ':')
		{
			free($4);
			$4 = mm_strdup("$0");
		}
		if ($2[0] == '$')
		{
			free($2);
			$2 = mm_strdup("$0");
		}

 $$ = cat_str(4,mm_strdup("relative"),$2,$3,$4);
}
|  SignedIconst opt_from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($3, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($3[0] == ':')
		{
			free($3);
			$3 = mm_strdup("$0");
		}
		if ($1[0] == '$')
		{
			free($1);
			$1 = mm_strdup("$0");
		}

 $$ = cat_str(3,$1,$2,$3);
}
|  ALL opt_from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($3, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($3[0] == ':')
		{
			free($3);
			$3 = mm_strdup("$0");
		}

 $$ = cat_str(3,mm_strdup("all"),$2,$3);
}
|  FORWARD SignedIconst opt_from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($4, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($4[0] == ':')
		{
			free($4);
			$4 = mm_strdup("$0");
		}
		if ($2[0] == '$')
		{
			free($2);
			$2 = mm_strdup("$0");
		}

 $$ = cat_str(4,mm_strdup("forward"),$2,$3,$4);
}
|  FORWARD ALL opt_from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($4, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($4[0] == ':')
		{
			free($4);
			$4 = mm_strdup("$0");
		}

 $$ = cat_str(3,mm_strdup("forward all"),$3,$4);
}
|  BACKWARD SignedIconst opt_from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($4, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($4[0] == ':')
		{
			free($4);
			$4 = mm_strdup("$0");
		}
		if ($2[0] == '$')
		{
			free($2);
			$2 = mm_strdup("$0");
		}

 $$ = cat_str(4,mm_strdup("backward"),$2,$3,$4);
}
|  BACKWARD ALL opt_from_in cursor_name
 { 
		struct cursor *ptr = add_additional_variables($4, false);
		if (ptr -> connection)
			connection = mm_strdup(ptr -> connection);

		if ($4[0] == ':')
		{
			free($4);
			$4 = mm_strdup("$0");
		}

 $$ = cat_str(3,mm_strdup("backward all"),$3,$4);
}
;


 from_in:
 FROM
 { 
 $$ = mm_strdup("from");
}
|  IN_P
 { 
 $$ = mm_strdup("in");
}
;


 opt_from_in:
 from_in
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 GrantStmt:
 GRANT privileges ON privilege_target TO grantee_list opt_grant_grant_option opt_granted_by
 { 
 $$ = cat_str(8,mm_strdup("grant"),$2,mm_strdup("on"),$4,mm_strdup("to"),$6,$7,$8);
}
;


 RevokeStmt:
 REVOKE privileges ON privilege_target FROM grantee_list opt_granted_by opt_drop_behavior
 { 
 $$ = cat_str(8,mm_strdup("revoke"),$2,mm_strdup("on"),$4,mm_strdup("from"),$6,$7,$8);
}
|  REVOKE GRANT OPTION FOR privileges ON privilege_target FROM grantee_list opt_granted_by opt_drop_behavior
 { 
 $$ = cat_str(8,mm_strdup("revoke grant option for"),$5,mm_strdup("on"),$7,mm_strdup("from"),$9,$10,$11);
}
;


 privileges:
 privilege_list
 { 
 $$ = $1;
}
|  ALL
 { 
 $$ = mm_strdup("all");
}
|  ALL PRIVILEGES
 { 
 $$ = mm_strdup("all privileges");
}
|  ALL '(' columnList ')'
 { 
 $$ = cat_str(3,mm_strdup("all ("),$3,mm_strdup(")"));
}
|  ALL PRIVILEGES '(' columnList ')'
 { 
 $$ = cat_str(3,mm_strdup("all privileges ("),$4,mm_strdup(")"));
}
;


 privilege_list:
 privilege
 { 
 $$ = $1;
}
|  privilege_list ',' privilege
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 privilege:
 SELECT opt_column_list
 { 
 $$ = cat_str(2,mm_strdup("select"),$2);
}
|  REFERENCES opt_column_list
 { 
 $$ = cat_str(2,mm_strdup("references"),$2);
}
|  CREATE opt_column_list
 { 
 $$ = cat_str(2,mm_strdup("create"),$2);
}
|  ColId opt_column_list
 { 
 $$ = cat_str(2,$1,$2);
}
;


 privilege_target:
 qualified_name_list
 { 
 $$ = $1;
}
|  TABLE qualified_name_list
 { 
 $$ = cat_str(2,mm_strdup("table"),$2);
}
|  SEQUENCE qualified_name_list
 { 
 $$ = cat_str(2,mm_strdup("sequence"),$2);
}
|  FOREIGN DATA_P WRAPPER name_list
 { 
 $$ = cat_str(2,mm_strdup("foreign data wrapper"),$4);
}
|  FOREIGN SERVER name_list
 { 
 $$ = cat_str(2,mm_strdup("foreign server"),$3);
}
|  FUNCTION function_with_argtypes_list
 { 
 $$ = cat_str(2,mm_strdup("function"),$2);
}
|  PROCEDURE function_with_argtypes_list
 { 
 $$ = cat_str(2,mm_strdup("procedure"),$2);
}
|  ROUTINE function_with_argtypes_list
 { 
 $$ = cat_str(2,mm_strdup("routine"),$2);
}
|  DATABASE name_list
 { 
 $$ = cat_str(2,mm_strdup("database"),$2);
}
|  DOMAIN_P any_name_list
 { 
 $$ = cat_str(2,mm_strdup("domain"),$2);
}
|  LANGUAGE name_list
 { 
 $$ = cat_str(2,mm_strdup("language"),$2);
}
|  LARGE_P OBJECT_P NumericOnly_list
 { 
 $$ = cat_str(2,mm_strdup("large object"),$3);
}
|  SCHEMA name_list
 { 
 $$ = cat_str(2,mm_strdup("schema"),$2);
}
|  TABLESPACE name_list
 { 
 $$ = cat_str(2,mm_strdup("tablespace"),$2);
}
|  TYPE_P any_name_list
 { 
 $$ = cat_str(2,mm_strdup("type"),$2);
}
|  ALL TABLES IN_P SCHEMA name_list
 { 
 $$ = cat_str(2,mm_strdup("all tables in schema"),$5);
}
|  ALL SEQUENCES IN_P SCHEMA name_list
 { 
 $$ = cat_str(2,mm_strdup("all sequences in schema"),$5);
}
|  ALL FUNCTIONS IN_P SCHEMA name_list
 { 
 $$ = cat_str(2,mm_strdup("all functions in schema"),$5);
}
|  ALL PROCEDURES IN_P SCHEMA name_list
 { 
 $$ = cat_str(2,mm_strdup("all procedures in schema"),$5);
}
|  ALL ROUTINES IN_P SCHEMA name_list
 { 
 $$ = cat_str(2,mm_strdup("all routines in schema"),$5);
}
;


 grantee_list:
 grantee
 { 
 $$ = $1;
}
|  grantee_list ',' grantee
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 grantee:
 RoleSpec
 { 
 $$ = $1;
}
|  GROUP_P RoleSpec
 { 
 $$ = cat_str(2,mm_strdup("group"),$2);
}
;


 opt_grant_grant_option:
 WITH GRANT OPTION
 { 
 $$ = mm_strdup("with grant option");
}
| 
 { 
 $$=EMPTY; }
;


 GrantRoleStmt:
 GRANT privilege_list TO role_list opt_grant_admin_option opt_granted_by
 { 
 $$ = cat_str(6,mm_strdup("grant"),$2,mm_strdup("to"),$4,$5,$6);
}
;


 RevokeRoleStmt:
 REVOKE privilege_list FROM role_list opt_granted_by opt_drop_behavior
 { 
 $$ = cat_str(6,mm_strdup("revoke"),$2,mm_strdup("from"),$4,$5,$6);
}
|  REVOKE ADMIN OPTION FOR privilege_list FROM role_list opt_granted_by opt_drop_behavior
 { 
 $$ = cat_str(6,mm_strdup("revoke admin option for"),$5,mm_strdup("from"),$7,$8,$9);
}
;


 opt_grant_admin_option:
 WITH ADMIN OPTION
 { 
 $$ = mm_strdup("with admin option");
}
| 
 { 
 $$=EMPTY; }
;


 opt_granted_by:
 GRANTED BY RoleSpec
 { 
 $$ = cat_str(2,mm_strdup("granted by"),$3);
}
| 
 { 
 $$=EMPTY; }
;


 AlterDefaultPrivilegesStmt:
 ALTER DEFAULT PRIVILEGES DefACLOptionList DefACLAction
 { 
 $$ = cat_str(3,mm_strdup("alter default privileges"),$4,$5);
}
;


 DefACLOptionList:
 DefACLOptionList DefACLOption
 { 
 $$ = cat_str(2,$1,$2);
}
| 
 { 
 $$=EMPTY; }
;


 DefACLOption:
 IN_P SCHEMA name_list
 { 
 $$ = cat_str(2,mm_strdup("in schema"),$3);
}
|  FOR ROLE role_list
 { 
 $$ = cat_str(2,mm_strdup("for role"),$3);
}
|  FOR USER role_list
 { 
 $$ = cat_str(2,mm_strdup("for user"),$3);
}
;


 DefACLAction:
 GRANT privileges ON defacl_privilege_target TO grantee_list opt_grant_grant_option
 { 
 $$ = cat_str(7,mm_strdup("grant"),$2,mm_strdup("on"),$4,mm_strdup("to"),$6,$7);
}
|  REVOKE privileges ON defacl_privilege_target FROM grantee_list opt_drop_behavior
 { 
 $$ = cat_str(7,mm_strdup("revoke"),$2,mm_strdup("on"),$4,mm_strdup("from"),$6,$7);
}
|  REVOKE GRANT OPTION FOR privileges ON defacl_privilege_target FROM grantee_list opt_drop_behavior
 { 
 $$ = cat_str(7,mm_strdup("revoke grant option for"),$5,mm_strdup("on"),$7,mm_strdup("from"),$9,$10);
}
;


 defacl_privilege_target:
 TABLES
 { 
 $$ = mm_strdup("tables");
}
|  FUNCTIONS
 { 
 $$ = mm_strdup("functions");
}
|  ROUTINES
 { 
 $$ = mm_strdup("routines");
}
|  SEQUENCES
 { 
 $$ = mm_strdup("sequences");
}
|  TYPES_P
 { 
 $$ = mm_strdup("types");
}
|  SCHEMAS
 { 
 $$ = mm_strdup("schemas");
}
;


 IndexStmt:
 CREATE opt_unique INDEX opt_concurrently opt_index_name ON relation_expr access_method_clause '(' index_params ')' opt_include opt_reloptions OptTableSpace where_clause
 { 
 $$ = cat_str(15,mm_strdup("create"),$2,mm_strdup("index"),$4,$5,mm_strdup("on"),$7,$8,mm_strdup("("),$10,mm_strdup(")"),$12,$13,$14,$15);
}
|  CREATE opt_unique INDEX opt_concurrently IF_P NOT EXISTS name ON relation_expr access_method_clause '(' index_params ')' opt_include opt_reloptions OptTableSpace where_clause
 { 
 $$ = cat_str(16,mm_strdup("create"),$2,mm_strdup("index"),$4,mm_strdup("if not exists"),$8,mm_strdup("on"),$10,$11,mm_strdup("("),$13,mm_strdup(")"),$15,$16,$17,$18);
}
;


 opt_unique:
 UNIQUE
 { 
 $$ = mm_strdup("unique");
}
| 
 { 
 $$=EMPTY; }
;


 opt_concurrently:
 CONCURRENTLY
 { 
 $$ = mm_strdup("concurrently");
}
| 
 { 
 $$=EMPTY; }
;


 opt_index_name:
 name
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 access_method_clause:
 USING name
 { 
 $$ = cat_str(2,mm_strdup("using"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 index_params:
 index_elem
 { 
 $$ = $1;
}
|  index_params ',' index_elem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 index_elem_options:
 opt_collate opt_class opt_asc_desc opt_nulls_order
 { 
 $$ = cat_str(4,$1,$2,$3,$4);
}
|  opt_collate any_name reloptions opt_asc_desc opt_nulls_order
 { 
 $$ = cat_str(5,$1,$2,$3,$4,$5);
}
;


 index_elem:
 ColId index_elem_options
 { 
 $$ = cat_str(2,$1,$2);
}
|  func_expr_windowless index_elem_options
 { 
 $$ = cat_str(2,$1,$2);
}
|  '(' a_expr ')' index_elem_options
 { 
 $$ = cat_str(4,mm_strdup("("),$2,mm_strdup(")"),$4);
}
;


 opt_include:
 INCLUDE '(' index_including_params ')'
 { 
 $$ = cat_str(3,mm_strdup("include ("),$3,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 index_including_params:
 index_elem
 { 
 $$ = $1;
}
|  index_including_params ',' index_elem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 opt_collate:
 COLLATE any_name
 { 
 $$ = cat_str(2,mm_strdup("collate"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 opt_class:
 any_name
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 opt_asc_desc:
 ASC
 { 
 $$ = mm_strdup("asc");
}
|  DESC
 { 
 $$ = mm_strdup("desc");
}
| 
 { 
 $$=EMPTY; }
;


 opt_nulls_order:
 NULLS_LA FIRST_P
 { 
 $$ = mm_strdup("nulls first");
}
|  NULLS_LA LAST_P
 { 
 $$ = mm_strdup("nulls last");
}
| 
 { 
 $$=EMPTY; }
;


 CreateFunctionStmt:
 CREATE opt_or_replace FUNCTION func_name func_args_with_defaults RETURNS func_return opt_createfunc_opt_list opt_routine_body
 { 
 $$ = cat_str(9,mm_strdup("create"),$2,mm_strdup("function"),$4,$5,mm_strdup("returns"),$7,$8,$9);
}
|  CREATE opt_or_replace FUNCTION func_name func_args_with_defaults RETURNS TABLE '(' table_func_column_list ')' opt_createfunc_opt_list opt_routine_body
 { 
 $$ = cat_str(10,mm_strdup("create"),$2,mm_strdup("function"),$4,$5,mm_strdup("returns table ("),$9,mm_strdup(")"),$11,$12);
}
|  CREATE opt_or_replace FUNCTION func_name func_args_with_defaults opt_createfunc_opt_list opt_routine_body
 { 
 $$ = cat_str(7,mm_strdup("create"),$2,mm_strdup("function"),$4,$5,$6,$7);
}
|  CREATE opt_or_replace PROCEDURE func_name func_args_with_defaults opt_createfunc_opt_list opt_routine_body
 { 
 $$ = cat_str(7,mm_strdup("create"),$2,mm_strdup("procedure"),$4,$5,$6,$7);
}
;


 opt_or_replace:
 OR REPLACE
 { 
 $$ = mm_strdup("or replace");
}
| 
 { 
 $$=EMPTY; }
;


 func_args:
 '(' func_args_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
|  '(' ')'
 { 
 $$ = mm_strdup("( )");
}
;


 func_args_list:
 func_arg
 { 
 $$ = $1;
}
|  func_args_list ',' func_arg
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 function_with_argtypes_list:
 function_with_argtypes
 { 
 $$ = $1;
}
|  function_with_argtypes_list ',' function_with_argtypes
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 function_with_argtypes:
 func_name func_args
 { 
 $$ = cat_str(2,$1,$2);
}
|  type_func_name_keyword
 { 
 $$ = $1;
}
|  ColId
 { 
 $$ = $1;
}
|  ColId indirection
 { 
 $$ = cat_str(2,$1,$2);
}
;


 func_args_with_defaults:
 '(' func_args_with_defaults_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
|  '(' ')'
 { 
 $$ = mm_strdup("( )");
}
;


 func_args_with_defaults_list:
 func_arg_with_default
 { 
 $$ = $1;
}
|  func_args_with_defaults_list ',' func_arg_with_default
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 func_arg:
 arg_class param_name func_type
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  param_name arg_class func_type
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  param_name func_type
 { 
 $$ = cat_str(2,$1,$2);
}
|  arg_class func_type
 { 
 $$ = cat_str(2,$1,$2);
}
|  func_type
 { 
 $$ = $1;
}
;


 arg_class:
 IN_P
 { 
 $$ = mm_strdup("in");
}
|  OUT_P
 { 
 $$ = mm_strdup("out");
}
|  INOUT
 { 
 $$ = mm_strdup("inout");
}
|  IN_P OUT_P
 { 
 $$ = mm_strdup("in out");
}
|  VARIADIC
 { 
 $$ = mm_strdup("variadic");
}
;


 param_name:
 type_function_name
 { 
 $$ = $1;
}
;


 func_return:
 func_type
 { 
 $$ = $1;
}
;


 func_type:
 Typename
 { 
 $$ = $1;
}
|  type_function_name attrs '%' TYPE_P
 { 
 $$ = cat_str(3,$1,$2,mm_strdup("% type"));
}
|  SETOF type_function_name attrs '%' TYPE_P
 { 
 $$ = cat_str(4,mm_strdup("setof"),$2,$3,mm_strdup("% type"));
}
;


 func_arg_with_default:
 func_arg
 { 
 $$ = $1;
}
|  func_arg DEFAULT a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("default"),$3);
}
|  func_arg '=' a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("="),$3);
}
;


 aggr_arg:
 func_arg
 { 
 $$ = $1;
}
;


 aggr_args:
 '(' '*' ')'
 { 
 $$ = mm_strdup("( * )");
}
|  '(' aggr_args_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
|  '(' ORDER BY aggr_args_list ')'
 { 
 $$ = cat_str(3,mm_strdup("( order by"),$4,mm_strdup(")"));
}
|  '(' aggr_args_list ORDER BY aggr_args_list ')'
 { 
 $$ = cat_str(5,mm_strdup("("),$2,mm_strdup("order by"),$5,mm_strdup(")"));
}
;


 aggr_args_list:
 aggr_arg
 { 
 $$ = $1;
}
|  aggr_args_list ',' aggr_arg
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 aggregate_with_argtypes:
 func_name aggr_args
 { 
 $$ = cat_str(2,$1,$2);
}
;


 aggregate_with_argtypes_list:
 aggregate_with_argtypes
 { 
 $$ = $1;
}
|  aggregate_with_argtypes_list ',' aggregate_with_argtypes
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 opt_createfunc_opt_list:
 createfunc_opt_list
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 createfunc_opt_list:
 createfunc_opt_item
 { 
 $$ = $1;
}
|  createfunc_opt_list createfunc_opt_item
 { 
 $$ = cat_str(2,$1,$2);
}
;


 common_func_opt_item:
 CALLED ON NULL_P INPUT_P
 { 
 $$ = mm_strdup("called on null input");
}
|  RETURNS NULL_P ON NULL_P INPUT_P
 { 
 $$ = mm_strdup("returns null on null input");
}
|  STRICT_P
 { 
 $$ = mm_strdup("strict");
}
|  IMMUTABLE
 { 
 $$ = mm_strdup("immutable");
}
|  STABLE
 { 
 $$ = mm_strdup("stable");
}
|  VOLATILE
 { 
 $$ = mm_strdup("volatile");
}
|  EXTERNAL SECURITY DEFINER
 { 
 $$ = mm_strdup("external security definer");
}
|  EXTERNAL SECURITY INVOKER
 { 
 $$ = mm_strdup("external security invoker");
}
|  SECURITY DEFINER
 { 
 $$ = mm_strdup("security definer");
}
|  SECURITY INVOKER
 { 
 $$ = mm_strdup("security invoker");
}
|  LEAKPROOF
 { 
 $$ = mm_strdup("leakproof");
}
|  NOT LEAKPROOF
 { 
 $$ = mm_strdup("not leakproof");
}
|  COST NumericOnly
 { 
 $$ = cat_str(2,mm_strdup("cost"),$2);
}
|  ROWS NumericOnly
 { 
 $$ = cat_str(2,mm_strdup("rows"),$2);
}
|  SUPPORT any_name
 { 
 $$ = cat_str(2,mm_strdup("support"),$2);
}
|  FunctionSetResetClause
 { 
 $$ = $1;
}
|  PARALLEL ColId
 { 
 $$ = cat_str(2,mm_strdup("parallel"),$2);
}
;


 createfunc_opt_item:
 AS func_as
 { 
 $$ = cat_str(2,mm_strdup("as"),$2);
}
|  LANGUAGE NonReservedWord_or_Sconst
 { 
 $$ = cat_str(2,mm_strdup("language"),$2);
}
|  TRANSFORM transform_type_list
 { 
 $$ = cat_str(2,mm_strdup("transform"),$2);
}
|  WINDOW
 { 
 $$ = mm_strdup("window");
}
|  common_func_opt_item
 { 
 $$ = $1;
}
;


 func_as:
 ecpg_sconst
 { 
 $$ = $1;
}
|  ecpg_sconst ',' ecpg_sconst
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 ReturnStmt:
 RETURN a_expr
 { 
 $$ = cat_str(2,mm_strdup("return"),$2);
}
;


 opt_routine_body:
 ReturnStmt
 { 
 $$ = $1;
}
|  BEGIN_P ATOMIC routine_body_stmt_list END_P
 { 
 $$ = cat_str(3,mm_strdup("begin atomic"),$3,mm_strdup("end"));
}
| 
 { 
 $$=EMPTY; }
;


 routine_body_stmt_list:
 routine_body_stmt_list routine_body_stmt ';'
 { 
 $$ = cat_str(3,$1,$2,mm_strdup(";"));
}
| 
 { 
 $$=EMPTY; }
;


 routine_body_stmt:
 stmt
 { 
 $$ = $1;
}
|  ReturnStmt
 { 
 $$ = $1;
}
;


 transform_type_list:
 FOR TYPE_P Typename
 { 
 $$ = cat_str(2,mm_strdup("for type"),$3);
}
|  transform_type_list ',' FOR TYPE_P Typename
 { 
 $$ = cat_str(3,$1,mm_strdup(", for type"),$5);
}
;


 opt_definition:
 WITH definition
 { 
 $$ = cat_str(2,mm_strdup("with"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 table_func_column:
 param_name func_type
 { 
 $$ = cat_str(2,$1,$2);
}
;


 table_func_column_list:
 table_func_column
 { 
 $$ = $1;
}
|  table_func_column_list ',' table_func_column
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 AlterFunctionStmt:
 ALTER FUNCTION function_with_argtypes alterfunc_opt_list opt_restrict
 { 
 $$ = cat_str(4,mm_strdup("alter function"),$3,$4,$5);
}
|  ALTER PROCEDURE function_with_argtypes alterfunc_opt_list opt_restrict
 { 
 $$ = cat_str(4,mm_strdup("alter procedure"),$3,$4,$5);
}
|  ALTER ROUTINE function_with_argtypes alterfunc_opt_list opt_restrict
 { 
 $$ = cat_str(4,mm_strdup("alter routine"),$3,$4,$5);
}
;


 alterfunc_opt_list:
 common_func_opt_item
 { 
 $$ = $1;
}
|  alterfunc_opt_list common_func_opt_item
 { 
 $$ = cat_str(2,$1,$2);
}
;


 opt_restrict:
 RESTRICT
 { 
 $$ = mm_strdup("restrict");
}
| 
 { 
 $$=EMPTY; }
;


 RemoveFuncStmt:
 DROP FUNCTION function_with_argtypes_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop function"),$3,$4);
}
|  DROP FUNCTION IF_P EXISTS function_with_argtypes_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop function if exists"),$5,$6);
}
|  DROP PROCEDURE function_with_argtypes_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop procedure"),$3,$4);
}
|  DROP PROCEDURE IF_P EXISTS function_with_argtypes_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop procedure if exists"),$5,$6);
}
|  DROP ROUTINE function_with_argtypes_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop routine"),$3,$4);
}
|  DROP ROUTINE IF_P EXISTS function_with_argtypes_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop routine if exists"),$5,$6);
}
;


 RemoveAggrStmt:
 DROP AGGREGATE aggregate_with_argtypes_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop aggregate"),$3,$4);
}
|  DROP AGGREGATE IF_P EXISTS aggregate_with_argtypes_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop aggregate if exists"),$5,$6);
}
;


 RemoveOperStmt:
 DROP OPERATOR operator_with_argtypes_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop operator"),$3,$4);
}
|  DROP OPERATOR IF_P EXISTS operator_with_argtypes_list opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop operator if exists"),$5,$6);
}
;


 oper_argtypes:
 '(' Typename ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
|  '(' Typename ',' Typename ')'
 { 
 $$ = cat_str(5,mm_strdup("("),$2,mm_strdup(","),$4,mm_strdup(")"));
}
|  '(' NONE ',' Typename ')'
 { 
 $$ = cat_str(3,mm_strdup("( none ,"),$4,mm_strdup(")"));
}
|  '(' Typename ',' NONE ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(", none )"));
}
;


 any_operator:
 all_Op
 { 
 $$ = $1;
}
|  ColId '.' any_operator
 { 
 $$ = cat_str(3,$1,mm_strdup("."),$3);
}
;


 operator_with_argtypes_list:
 operator_with_argtypes
 { 
 $$ = $1;
}
|  operator_with_argtypes_list ',' operator_with_argtypes
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 operator_with_argtypes:
 any_operator oper_argtypes
 { 
 $$ = cat_str(2,$1,$2);
}
;


 DoStmt:
 DO dostmt_opt_list
 { 
 $$ = cat_str(2,mm_strdup("do"),$2);
}
;


 dostmt_opt_list:
 dostmt_opt_item
 { 
 $$ = $1;
}
|  dostmt_opt_list dostmt_opt_item
 { 
 $$ = cat_str(2,$1,$2);
}
;


 dostmt_opt_item:
 ecpg_sconst
 { 
 $$ = $1;
}
|  LANGUAGE NonReservedWord_or_Sconst
 { 
 $$ = cat_str(2,mm_strdup("language"),$2);
}
;


 CreateCastStmt:
 CREATE CAST '(' Typename AS Typename ')' WITH FUNCTION function_with_argtypes cast_context
 { 
 $$ = cat_str(7,mm_strdup("create cast ("),$4,mm_strdup("as"),$6,mm_strdup(") with function"),$10,$11);
}
|  CREATE CAST '(' Typename AS Typename ')' WITHOUT FUNCTION cast_context
 { 
 $$ = cat_str(6,mm_strdup("create cast ("),$4,mm_strdup("as"),$6,mm_strdup(") without function"),$10);
}
|  CREATE CAST '(' Typename AS Typename ')' WITH INOUT cast_context
 { 
 $$ = cat_str(6,mm_strdup("create cast ("),$4,mm_strdup("as"),$6,mm_strdup(") with inout"),$10);
}
;


 cast_context:
 AS IMPLICIT_P
 { 
 $$ = mm_strdup("as implicit");
}
|  AS ASSIGNMENT
 { 
 $$ = mm_strdup("as assignment");
}
| 
 { 
 $$=EMPTY; }
;


 DropCastStmt:
 DROP CAST opt_if_exists '(' Typename AS Typename ')' opt_drop_behavior
 { 
 $$ = cat_str(8,mm_strdup("drop cast"),$3,mm_strdup("("),$5,mm_strdup("as"),$7,mm_strdup(")"),$9);
}
;


 opt_if_exists:
 IF_P EXISTS
 { 
 $$ = mm_strdup("if exists");
}
| 
 { 
 $$=EMPTY; }
;


 CreateTransformStmt:
 CREATE opt_or_replace TRANSFORM FOR Typename LANGUAGE name '(' transform_element_list ')'
 { 
 $$ = cat_str(9,mm_strdup("create"),$2,mm_strdup("transform for"),$5,mm_strdup("language"),$7,mm_strdup("("),$9,mm_strdup(")"));
}
;


 transform_element_list:
 FROM SQL_P WITH FUNCTION function_with_argtypes ',' TO SQL_P WITH FUNCTION function_with_argtypes
 { 
 $$ = cat_str(4,mm_strdup("from sql with function"),$5,mm_strdup(", to sql with function"),$11);
}
|  TO SQL_P WITH FUNCTION function_with_argtypes ',' FROM SQL_P WITH FUNCTION function_with_argtypes
 { 
 $$ = cat_str(4,mm_strdup("to sql with function"),$5,mm_strdup(", from sql with function"),$11);
}
|  FROM SQL_P WITH FUNCTION function_with_argtypes
 { 
 $$ = cat_str(2,mm_strdup("from sql with function"),$5);
}
|  TO SQL_P WITH FUNCTION function_with_argtypes
 { 
 $$ = cat_str(2,mm_strdup("to sql with function"),$5);
}
;


 DropTransformStmt:
 DROP TRANSFORM opt_if_exists FOR Typename LANGUAGE name opt_drop_behavior
 { 
 $$ = cat_str(7,mm_strdup("drop transform"),$3,mm_strdup("for"),$5,mm_strdup("language"),$7,$8);
}
;


 ReindexStmt:
 REINDEX reindex_target_type opt_concurrently qualified_name
 { 
 $$ = cat_str(4,mm_strdup("reindex"),$2,$3,$4);
}
|  REINDEX reindex_target_multitable opt_concurrently name
 { 
 $$ = cat_str(4,mm_strdup("reindex"),$2,$3,$4);
}
|  REINDEX '(' utility_option_list ')' reindex_target_type opt_concurrently qualified_name
 { 
 $$ = cat_str(6,mm_strdup("reindex ("),$3,mm_strdup(")"),$5,$6,$7);
}
|  REINDEX '(' utility_option_list ')' reindex_target_multitable opt_concurrently name
 { 
 $$ = cat_str(6,mm_strdup("reindex ("),$3,mm_strdup(")"),$5,$6,$7);
}
;


 reindex_target_type:
 INDEX
 { 
 $$ = mm_strdup("index");
}
|  TABLE
 { 
 $$ = mm_strdup("table");
}
;


 reindex_target_multitable:
 SCHEMA
 { 
 $$ = mm_strdup("schema");
}
|  SYSTEM_P
 { 
 $$ = mm_strdup("system");
}
|  DATABASE
 { 
 $$ = mm_strdup("database");
}
;


 AlterTblSpcStmt:
 ALTER TABLESPACE name SET reloptions
 { 
 $$ = cat_str(4,mm_strdup("alter tablespace"),$3,mm_strdup("set"),$5);
}
|  ALTER TABLESPACE name RESET reloptions
 { 
 $$ = cat_str(4,mm_strdup("alter tablespace"),$3,mm_strdup("reset"),$5);
}
;


 RenameStmt:
 ALTER AGGREGATE aggregate_with_argtypes RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter aggregate"),$3,mm_strdup("rename to"),$6);
}
|  ALTER COLLATION any_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter collation"),$3,mm_strdup("rename to"),$6);
}
|  ALTER CONVERSION_P any_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter conversion"),$3,mm_strdup("rename to"),$6);
}
|  ALTER DATABASE name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter database"),$3,mm_strdup("rename to"),$6);
}
|  ALTER DOMAIN_P any_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter domain"),$3,mm_strdup("rename to"),$6);
}
|  ALTER DOMAIN_P any_name RENAME CONSTRAINT name TO name
 { 
 $$ = cat_str(6,mm_strdup("alter domain"),$3,mm_strdup("rename constraint"),$6,mm_strdup("to"),$8);
}
|  ALTER FOREIGN DATA_P WRAPPER name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter foreign data wrapper"),$5,mm_strdup("rename to"),$8);
}
|  ALTER FUNCTION function_with_argtypes RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter function"),$3,mm_strdup("rename to"),$6);
}
|  ALTER GROUP_P RoleId RENAME TO RoleId
 { 
 $$ = cat_str(4,mm_strdup("alter group"),$3,mm_strdup("rename to"),$6);
}
|  ALTER opt_procedural LANGUAGE name RENAME TO name
 { 
 $$ = cat_str(6,mm_strdup("alter"),$2,mm_strdup("language"),$4,mm_strdup("rename to"),$7);
}
|  ALTER OPERATOR CLASS any_name USING name RENAME TO name
 { 
 $$ = cat_str(6,mm_strdup("alter operator class"),$4,mm_strdup("using"),$6,mm_strdup("rename to"),$9);
}
|  ALTER OPERATOR FAMILY any_name USING name RENAME TO name
 { 
 $$ = cat_str(6,mm_strdup("alter operator family"),$4,mm_strdup("using"),$6,mm_strdup("rename to"),$9);
}
|  ALTER POLICY name ON qualified_name RENAME TO name
 { 
 $$ = cat_str(6,mm_strdup("alter policy"),$3,mm_strdup("on"),$5,mm_strdup("rename to"),$8);
}
|  ALTER POLICY IF_P EXISTS name ON qualified_name RENAME TO name
 { 
 $$ = cat_str(6,mm_strdup("alter policy if exists"),$5,mm_strdup("on"),$7,mm_strdup("rename to"),$10);
}
|  ALTER PROCEDURE function_with_argtypes RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter procedure"),$3,mm_strdup("rename to"),$6);
}
|  ALTER PUBLICATION name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter publication"),$3,mm_strdup("rename to"),$6);
}
|  ALTER ROUTINE function_with_argtypes RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter routine"),$3,mm_strdup("rename to"),$6);
}
|  ALTER SCHEMA name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter schema"),$3,mm_strdup("rename to"),$6);
}
|  ALTER SERVER name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter server"),$3,mm_strdup("rename to"),$6);
}
|  ALTER SUBSCRIPTION name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter subscription"),$3,mm_strdup("rename to"),$6);
}
|  ALTER TABLE relation_expr RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter table"),$3,mm_strdup("rename to"),$6);
}
|  ALTER TABLE IF_P EXISTS relation_expr RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter table if exists"),$5,mm_strdup("rename to"),$8);
}
|  ALTER SEQUENCE qualified_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter sequence"),$3,mm_strdup("rename to"),$6);
}
|  ALTER SEQUENCE IF_P EXISTS qualified_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter sequence if exists"),$5,mm_strdup("rename to"),$8);
}
|  ALTER VIEW qualified_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter view"),$3,mm_strdup("rename to"),$6);
}
|  ALTER VIEW IF_P EXISTS qualified_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter view if exists"),$5,mm_strdup("rename to"),$8);
}
|  ALTER MATERIALIZED VIEW qualified_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter materialized view"),$4,mm_strdup("rename to"),$7);
}
|  ALTER MATERIALIZED VIEW IF_P EXISTS qualified_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter materialized view if exists"),$6,mm_strdup("rename to"),$9);
}
|  ALTER INDEX qualified_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter index"),$3,mm_strdup("rename to"),$6);
}
|  ALTER INDEX IF_P EXISTS qualified_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter index if exists"),$5,mm_strdup("rename to"),$8);
}
|  ALTER FOREIGN TABLE relation_expr RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter foreign table"),$4,mm_strdup("rename to"),$7);
}
|  ALTER FOREIGN TABLE IF_P EXISTS relation_expr RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter foreign table if exists"),$6,mm_strdup("rename to"),$9);
}
|  ALTER TABLE relation_expr RENAME opt_column name TO name
 { 
 $$ = cat_str(7,mm_strdup("alter table"),$3,mm_strdup("rename"),$5,$6,mm_strdup("to"),$8);
}
|  ALTER TABLE IF_P EXISTS relation_expr RENAME opt_column name TO name
 { 
 $$ = cat_str(7,mm_strdup("alter table if exists"),$5,mm_strdup("rename"),$7,$8,mm_strdup("to"),$10);
}
|  ALTER VIEW qualified_name RENAME opt_column name TO name
 { 
 $$ = cat_str(7,mm_strdup("alter view"),$3,mm_strdup("rename"),$5,$6,mm_strdup("to"),$8);
}
|  ALTER VIEW IF_P EXISTS qualified_name RENAME opt_column name TO name
 { 
 $$ = cat_str(7,mm_strdup("alter view if exists"),$5,mm_strdup("rename"),$7,$8,mm_strdup("to"),$10);
}
|  ALTER MATERIALIZED VIEW qualified_name RENAME opt_column name TO name
 { 
 $$ = cat_str(7,mm_strdup("alter materialized view"),$4,mm_strdup("rename"),$6,$7,mm_strdup("to"),$9);
}
|  ALTER MATERIALIZED VIEW IF_P EXISTS qualified_name RENAME opt_column name TO name
 { 
 $$ = cat_str(7,mm_strdup("alter materialized view if exists"),$6,mm_strdup("rename"),$8,$9,mm_strdup("to"),$11);
}
|  ALTER TABLE relation_expr RENAME CONSTRAINT name TO name
 { 
 $$ = cat_str(6,mm_strdup("alter table"),$3,mm_strdup("rename constraint"),$6,mm_strdup("to"),$8);
}
|  ALTER TABLE IF_P EXISTS relation_expr RENAME CONSTRAINT name TO name
 { 
 $$ = cat_str(6,mm_strdup("alter table if exists"),$5,mm_strdup("rename constraint"),$8,mm_strdup("to"),$10);
}
|  ALTER FOREIGN TABLE relation_expr RENAME opt_column name TO name
 { 
 $$ = cat_str(7,mm_strdup("alter foreign table"),$4,mm_strdup("rename"),$6,$7,mm_strdup("to"),$9);
}
|  ALTER FOREIGN TABLE IF_P EXISTS relation_expr RENAME opt_column name TO name
 { 
 $$ = cat_str(7,mm_strdup("alter foreign table if exists"),$6,mm_strdup("rename"),$8,$9,mm_strdup("to"),$11);
}
|  ALTER RULE name ON qualified_name RENAME TO name
 { 
 $$ = cat_str(6,mm_strdup("alter rule"),$3,mm_strdup("on"),$5,mm_strdup("rename to"),$8);
}
|  ALTER TRIGGER name ON qualified_name RENAME TO name
 { 
 $$ = cat_str(6,mm_strdup("alter trigger"),$3,mm_strdup("on"),$5,mm_strdup("rename to"),$8);
}
|  ALTER EVENT TRIGGER name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter event trigger"),$4,mm_strdup("rename to"),$7);
}
|  ALTER ROLE RoleId RENAME TO RoleId
 { 
 $$ = cat_str(4,mm_strdup("alter role"),$3,mm_strdup("rename to"),$6);
}
|  ALTER USER RoleId RENAME TO RoleId
 { 
 $$ = cat_str(4,mm_strdup("alter user"),$3,mm_strdup("rename to"),$6);
}
|  ALTER TABLESPACE name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter tablespace"),$3,mm_strdup("rename to"),$6);
}
|  ALTER STATISTICS any_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter statistics"),$3,mm_strdup("rename to"),$6);
}
|  ALTER TEXT_P SEARCH PARSER any_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter text search parser"),$5,mm_strdup("rename to"),$8);
}
|  ALTER TEXT_P SEARCH DICTIONARY any_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter text search dictionary"),$5,mm_strdup("rename to"),$8);
}
|  ALTER TEXT_P SEARCH TEMPLATE any_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter text search template"),$5,mm_strdup("rename to"),$8);
}
|  ALTER TEXT_P SEARCH CONFIGURATION any_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter text search configuration"),$5,mm_strdup("rename to"),$8);
}
|  ALTER TYPE_P any_name RENAME TO name
 { 
 $$ = cat_str(4,mm_strdup("alter type"),$3,mm_strdup("rename to"),$6);
}
|  ALTER TYPE_P any_name RENAME ATTRIBUTE name TO name opt_drop_behavior
 { 
 $$ = cat_str(7,mm_strdup("alter type"),$3,mm_strdup("rename attribute"),$6,mm_strdup("to"),$8,$9);
}
;


 opt_column:
 COLUMN
 { 
 $$ = mm_strdup("column");
}
| 
 { 
 $$=EMPTY; }
;


 opt_set_data:
 SET DATA_P
 { 
 $$ = mm_strdup("set data");
}
| 
 { 
 $$=EMPTY; }
;


 AlterObjectDependsStmt:
 ALTER FUNCTION function_with_argtypes opt_no DEPENDS ON EXTENSION name
 { 
 $$ = cat_str(5,mm_strdup("alter function"),$3,$4,mm_strdup("depends on extension"),$8);
}
|  ALTER PROCEDURE function_with_argtypes opt_no DEPENDS ON EXTENSION name
 { 
 $$ = cat_str(5,mm_strdup("alter procedure"),$3,$4,mm_strdup("depends on extension"),$8);
}
|  ALTER ROUTINE function_with_argtypes opt_no DEPENDS ON EXTENSION name
 { 
 $$ = cat_str(5,mm_strdup("alter routine"),$3,$4,mm_strdup("depends on extension"),$8);
}
|  ALTER TRIGGER name ON qualified_name opt_no DEPENDS ON EXTENSION name
 { 
 $$ = cat_str(7,mm_strdup("alter trigger"),$3,mm_strdup("on"),$5,$6,mm_strdup("depends on extension"),$10);
}
|  ALTER MATERIALIZED VIEW qualified_name opt_no DEPENDS ON EXTENSION name
 { 
 $$ = cat_str(5,mm_strdup("alter materialized view"),$4,$5,mm_strdup("depends on extension"),$9);
}
|  ALTER INDEX qualified_name opt_no DEPENDS ON EXTENSION name
 { 
 $$ = cat_str(5,mm_strdup("alter index"),$3,$4,mm_strdup("depends on extension"),$8);
}
;


 opt_no:
 NO
 { 
 $$ = mm_strdup("no");
}
| 
 { 
 $$=EMPTY; }
;


 AlterObjectSchemaStmt:
 ALTER AGGREGATE aggregate_with_argtypes SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter aggregate"),$3,mm_strdup("set schema"),$6);
}
|  ALTER COLLATION any_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter collation"),$3,mm_strdup("set schema"),$6);
}
|  ALTER CONVERSION_P any_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter conversion"),$3,mm_strdup("set schema"),$6);
}
|  ALTER DOMAIN_P any_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter domain"),$3,mm_strdup("set schema"),$6);
}
|  ALTER EXTENSION name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter extension"),$3,mm_strdup("set schema"),$6);
}
|  ALTER FUNCTION function_with_argtypes SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter function"),$3,mm_strdup("set schema"),$6);
}
|  ALTER OPERATOR operator_with_argtypes SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter operator"),$3,mm_strdup("set schema"),$6);
}
|  ALTER OPERATOR CLASS any_name USING name SET SCHEMA name
 { 
 $$ = cat_str(6,mm_strdup("alter operator class"),$4,mm_strdup("using"),$6,mm_strdup("set schema"),$9);
}
|  ALTER OPERATOR FAMILY any_name USING name SET SCHEMA name
 { 
 $$ = cat_str(6,mm_strdup("alter operator family"),$4,mm_strdup("using"),$6,mm_strdup("set schema"),$9);
}
|  ALTER PROCEDURE function_with_argtypes SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter procedure"),$3,mm_strdup("set schema"),$6);
}
|  ALTER ROUTINE function_with_argtypes SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter routine"),$3,mm_strdup("set schema"),$6);
}
|  ALTER TABLE relation_expr SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter table"),$3,mm_strdup("set schema"),$6);
}
|  ALTER TABLE IF_P EXISTS relation_expr SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter table if exists"),$5,mm_strdup("set schema"),$8);
}
|  ALTER STATISTICS any_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter statistics"),$3,mm_strdup("set schema"),$6);
}
|  ALTER TEXT_P SEARCH PARSER any_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter text search parser"),$5,mm_strdup("set schema"),$8);
}
|  ALTER TEXT_P SEARCH DICTIONARY any_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter text search dictionary"),$5,mm_strdup("set schema"),$8);
}
|  ALTER TEXT_P SEARCH TEMPLATE any_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter text search template"),$5,mm_strdup("set schema"),$8);
}
|  ALTER TEXT_P SEARCH CONFIGURATION any_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter text search configuration"),$5,mm_strdup("set schema"),$8);
}
|  ALTER SEQUENCE qualified_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter sequence"),$3,mm_strdup("set schema"),$6);
}
|  ALTER SEQUENCE IF_P EXISTS qualified_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter sequence if exists"),$5,mm_strdup("set schema"),$8);
}
|  ALTER VIEW qualified_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter view"),$3,mm_strdup("set schema"),$6);
}
|  ALTER VIEW IF_P EXISTS qualified_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter view if exists"),$5,mm_strdup("set schema"),$8);
}
|  ALTER MATERIALIZED VIEW qualified_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter materialized view"),$4,mm_strdup("set schema"),$7);
}
|  ALTER MATERIALIZED VIEW IF_P EXISTS qualified_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter materialized view if exists"),$6,mm_strdup("set schema"),$9);
}
|  ALTER FOREIGN TABLE relation_expr SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter foreign table"),$4,mm_strdup("set schema"),$7);
}
|  ALTER FOREIGN TABLE IF_P EXISTS relation_expr SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter foreign table if exists"),$6,mm_strdup("set schema"),$9);
}
|  ALTER TYPE_P any_name SET SCHEMA name
 { 
 $$ = cat_str(4,mm_strdup("alter type"),$3,mm_strdup("set schema"),$6);
}
;


 AlterOperatorStmt:
 ALTER OPERATOR operator_with_argtypes SET '(' operator_def_list ')'
 { 
 $$ = cat_str(5,mm_strdup("alter operator"),$3,mm_strdup("set ("),$6,mm_strdup(")"));
}
;


 operator_def_list:
 operator_def_elem
 { 
 $$ = $1;
}
|  operator_def_list ',' operator_def_elem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 operator_def_elem:
 ColLabel '=' NONE
 { 
 $$ = cat_str(2,$1,mm_strdup("= none"));
}
|  ColLabel '=' operator_def_arg
 { 
 $$ = cat_str(3,$1,mm_strdup("="),$3);
}
;


 operator_def_arg:
 func_type
 { 
 $$ = $1;
}
|  reserved_keyword
 { 
 $$ = $1;
}
|  qual_all_Op
 { 
 $$ = $1;
}
|  NumericOnly
 { 
 $$ = $1;
}
|  ecpg_sconst
 { 
 $$ = $1;
}
;


 AlterTypeStmt:
 ALTER TYPE_P any_name SET '(' operator_def_list ')'
 { 
 $$ = cat_str(5,mm_strdup("alter type"),$3,mm_strdup("set ("),$6,mm_strdup(")"));
}
;


 AlterOwnerStmt:
 ALTER AGGREGATE aggregate_with_argtypes OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter aggregate"),$3,mm_strdup("owner to"),$6);
}
|  ALTER COLLATION any_name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter collation"),$3,mm_strdup("owner to"),$6);
}
|  ALTER CONVERSION_P any_name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter conversion"),$3,mm_strdup("owner to"),$6);
}
|  ALTER DATABASE name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter database"),$3,mm_strdup("owner to"),$6);
}
|  ALTER DOMAIN_P any_name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter domain"),$3,mm_strdup("owner to"),$6);
}
|  ALTER FUNCTION function_with_argtypes OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter function"),$3,mm_strdup("owner to"),$6);
}
|  ALTER opt_procedural LANGUAGE name OWNER TO RoleSpec
 { 
 $$ = cat_str(6,mm_strdup("alter"),$2,mm_strdup("language"),$4,mm_strdup("owner to"),$7);
}
|  ALTER LARGE_P OBJECT_P NumericOnly OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter large object"),$4,mm_strdup("owner to"),$7);
}
|  ALTER OPERATOR operator_with_argtypes OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter operator"),$3,mm_strdup("owner to"),$6);
}
|  ALTER OPERATOR CLASS any_name USING name OWNER TO RoleSpec
 { 
 $$ = cat_str(6,mm_strdup("alter operator class"),$4,mm_strdup("using"),$6,mm_strdup("owner to"),$9);
}
|  ALTER OPERATOR FAMILY any_name USING name OWNER TO RoleSpec
 { 
 $$ = cat_str(6,mm_strdup("alter operator family"),$4,mm_strdup("using"),$6,mm_strdup("owner to"),$9);
}
|  ALTER PROCEDURE function_with_argtypes OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter procedure"),$3,mm_strdup("owner to"),$6);
}
|  ALTER ROUTINE function_with_argtypes OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter routine"),$3,mm_strdup("owner to"),$6);
}
|  ALTER SCHEMA name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter schema"),$3,mm_strdup("owner to"),$6);
}
|  ALTER TYPE_P any_name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter type"),$3,mm_strdup("owner to"),$6);
}
|  ALTER TABLESPACE name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter tablespace"),$3,mm_strdup("owner to"),$6);
}
|  ALTER STATISTICS any_name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter statistics"),$3,mm_strdup("owner to"),$6);
}
|  ALTER TEXT_P SEARCH DICTIONARY any_name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter text search dictionary"),$5,mm_strdup("owner to"),$8);
}
|  ALTER TEXT_P SEARCH CONFIGURATION any_name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter text search configuration"),$5,mm_strdup("owner to"),$8);
}
|  ALTER FOREIGN DATA_P WRAPPER name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter foreign data wrapper"),$5,mm_strdup("owner to"),$8);
}
|  ALTER SERVER name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter server"),$3,mm_strdup("owner to"),$6);
}
|  ALTER EVENT TRIGGER name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter event trigger"),$4,mm_strdup("owner to"),$7);
}
|  ALTER PUBLICATION name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter publication"),$3,mm_strdup("owner to"),$6);
}
|  ALTER SUBSCRIPTION name OWNER TO RoleSpec
 { 
 $$ = cat_str(4,mm_strdup("alter subscription"),$3,mm_strdup("owner to"),$6);
}
;


 CreatePublicationStmt:
 CREATE PUBLICATION name opt_publication_for_tables opt_definition
 { 
 $$ = cat_str(4,mm_strdup("create publication"),$3,$4,$5);
}
;


 opt_publication_for_tables:
 publication_for_tables
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 publication_for_tables:
 FOR TABLE relation_expr_list
 { 
 $$ = cat_str(2,mm_strdup("for table"),$3);
}
|  FOR ALL TABLES
 { 
 $$ = mm_strdup("for all tables");
}
;


 AlterPublicationStmt:
 ALTER PUBLICATION name SET definition
 { 
 $$ = cat_str(4,mm_strdup("alter publication"),$3,mm_strdup("set"),$5);
}
|  ALTER PUBLICATION name ADD_P TABLE relation_expr_list
 { 
 $$ = cat_str(4,mm_strdup("alter publication"),$3,mm_strdup("add table"),$6);
}
|  ALTER PUBLICATION name SET TABLE relation_expr_list
 { 
 $$ = cat_str(4,mm_strdup("alter publication"),$3,mm_strdup("set table"),$6);
}
|  ALTER PUBLICATION name DROP TABLE relation_expr_list
 { 
 $$ = cat_str(4,mm_strdup("alter publication"),$3,mm_strdup("drop table"),$6);
}
;


 CreateSubscriptionStmt:
 CREATE SUBSCRIPTION name CONNECTION ecpg_sconst PUBLICATION name_list opt_definition
 { 
 $$ = cat_str(7,mm_strdup("create subscription"),$3,mm_strdup("connection"),$5,mm_strdup("publication"),$7,$8);
}
;


 AlterSubscriptionStmt:
 ALTER SUBSCRIPTION name SET definition
 { 
 $$ = cat_str(4,mm_strdup("alter subscription"),$3,mm_strdup("set"),$5);
}
|  ALTER SUBSCRIPTION name CONNECTION ecpg_sconst
 { 
 $$ = cat_str(4,mm_strdup("alter subscription"),$3,mm_strdup("connection"),$5);
}
|  ALTER SUBSCRIPTION name REFRESH PUBLICATION opt_definition
 { 
 $$ = cat_str(4,mm_strdup("alter subscription"),$3,mm_strdup("refresh publication"),$6);
}
|  ALTER SUBSCRIPTION name ADD_P PUBLICATION name_list opt_definition
 { 
 $$ = cat_str(5,mm_strdup("alter subscription"),$3,mm_strdup("add publication"),$6,$7);
}
|  ALTER SUBSCRIPTION name DROP PUBLICATION name_list opt_definition
 { 
 $$ = cat_str(5,mm_strdup("alter subscription"),$3,mm_strdup("drop publication"),$6,$7);
}
|  ALTER SUBSCRIPTION name SET PUBLICATION name_list opt_definition
 { 
 $$ = cat_str(5,mm_strdup("alter subscription"),$3,mm_strdup("set publication"),$6,$7);
}
|  ALTER SUBSCRIPTION name ENABLE_P
 { 
 $$ = cat_str(3,mm_strdup("alter subscription"),$3,mm_strdup("enable"));
}
|  ALTER SUBSCRIPTION name DISABLE_P
 { 
 $$ = cat_str(3,mm_strdup("alter subscription"),$3,mm_strdup("disable"));
}
;


 DropSubscriptionStmt:
 DROP SUBSCRIPTION name opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop subscription"),$3,$4);
}
|  DROP SUBSCRIPTION IF_P EXISTS name opt_drop_behavior
 { 
 $$ = cat_str(3,mm_strdup("drop subscription if exists"),$5,$6);
}
;


 RuleStmt:
 CREATE opt_or_replace RULE name AS ON event TO qualified_name where_clause DO opt_instead RuleActionList
 { 
 $$ = cat_str(12,mm_strdup("create"),$2,mm_strdup("rule"),$4,mm_strdup("as on"),$7,mm_strdup("to"),$9,$10,mm_strdup("do"),$12,$13);
}
;


 RuleActionList:
 NOTHING
 { 
 $$ = mm_strdup("nothing");
}
|  RuleActionStmt
 { 
 $$ = $1;
}
|  '(' RuleActionMulti ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
;


 RuleActionMulti:
 RuleActionMulti ';' RuleActionStmtOrEmpty
 { 
 $$ = cat_str(3,$1,mm_strdup(";"),$3);
}
|  RuleActionStmtOrEmpty
 { 
 $$ = $1;
}
;


 RuleActionStmt:
 SelectStmt
 { 
 $$ = $1;
}
|  InsertStmt
 { 
 $$ = $1;
}
|  UpdateStmt
 { 
 $$ = $1;
}
|  DeleteStmt
 { 
 $$ = $1;
}
|  NotifyStmt
 { 
 $$ = $1;
}
;


 RuleActionStmtOrEmpty:
 RuleActionStmt
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 event:
 SELECT
 { 
 $$ = mm_strdup("select");
}
|  UPDATE
 { 
 $$ = mm_strdup("update");
}
|  DELETE_P
 { 
 $$ = mm_strdup("delete");
}
|  INSERT
 { 
 $$ = mm_strdup("insert");
}
;


 opt_instead:
 INSTEAD
 { 
 $$ = mm_strdup("instead");
}
|  ALSO
 { 
 $$ = mm_strdup("also");
}
| 
 { 
 $$=EMPTY; }
;


 NotifyStmt:
 NOTIFY ColId notify_payload
 { 
 $$ = cat_str(3,mm_strdup("notify"),$2,$3);
}
;


 notify_payload:
 ',' ecpg_sconst
 { 
 $$ = cat_str(2,mm_strdup(","),$2);
}
| 
 { 
 $$=EMPTY; }
;


 ListenStmt:
 LISTEN ColId
 { 
 $$ = cat_str(2,mm_strdup("listen"),$2);
}
;


 UnlistenStmt:
 UNLISTEN ColId
 { 
 $$ = cat_str(2,mm_strdup("unlisten"),$2);
}
|  UNLISTEN '*'
 { 
 $$ = mm_strdup("unlisten *");
}
;


 TransactionStmt:
 ABORT_P opt_transaction opt_transaction_chain
 { 
 $$ = cat_str(3,mm_strdup("abort"),$2,$3);
}
|  START TRANSACTION transaction_mode_list_or_empty
 { 
 $$ = cat_str(2,mm_strdup("start transaction"),$3);
}
|  COMMIT opt_transaction opt_transaction_chain
 { 
 $$ = cat_str(3,mm_strdup("commit"),$2,$3);
}
|  ROLLBACK opt_transaction opt_transaction_chain
 { 
 $$ = cat_str(3,mm_strdup("rollback"),$2,$3);
}
|  SAVEPOINT ColId
 { 
 $$ = cat_str(2,mm_strdup("savepoint"),$2);
}
|  RELEASE SAVEPOINT ColId
 { 
 $$ = cat_str(2,mm_strdup("release savepoint"),$3);
}
|  RELEASE ColId
 { 
 $$ = cat_str(2,mm_strdup("release"),$2);
}
|  ROLLBACK opt_transaction TO SAVEPOINT ColId
 { 
 $$ = cat_str(4,mm_strdup("rollback"),$2,mm_strdup("to savepoint"),$5);
}
|  ROLLBACK opt_transaction TO ColId
 { 
 $$ = cat_str(4,mm_strdup("rollback"),$2,mm_strdup("to"),$4);
}
|  PREPARE TRANSACTION ecpg_sconst
 { 
 $$ = cat_str(2,mm_strdup("prepare transaction"),$3);
}
|  COMMIT PREPARED ecpg_sconst
 { 
 $$ = cat_str(2,mm_strdup("commit prepared"),$3);
}
|  ROLLBACK PREPARED ecpg_sconst
 { 
 $$ = cat_str(2,mm_strdup("rollback prepared"),$3);
}
;


 TransactionStmtLegacy:
 BEGIN_P opt_transaction transaction_mode_list_or_empty
 { 
 $$ = cat_str(3,mm_strdup("begin"),$2,$3);
}
|  END_P opt_transaction opt_transaction_chain
 { 
 $$ = cat_str(3,mm_strdup("end"),$2,$3);
}
;


 opt_transaction:
 WORK
 { 
 $$ = mm_strdup("work");
}
|  TRANSACTION
 { 
 $$ = mm_strdup("transaction");
}
| 
 { 
 $$=EMPTY; }
;


 transaction_mode_item:
 ISOLATION LEVEL iso_level
 { 
 $$ = cat_str(2,mm_strdup("isolation level"),$3);
}
|  READ ONLY
 { 
 $$ = mm_strdup("read only");
}
|  READ WRITE
 { 
 $$ = mm_strdup("read write");
}
|  DEFERRABLE
 { 
 $$ = mm_strdup("deferrable");
}
|  NOT DEFERRABLE
 { 
 $$ = mm_strdup("not deferrable");
}
;


 transaction_mode_list:
 transaction_mode_item
 { 
 $$ = $1;
}
|  transaction_mode_list ',' transaction_mode_item
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
|  transaction_mode_list transaction_mode_item
 { 
 $$ = cat_str(2,$1,$2);
}
;


 transaction_mode_list_or_empty:
 transaction_mode_list
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 opt_transaction_chain:
 AND CHAIN
 { 
 $$ = mm_strdup("and chain");
}
|  AND NO CHAIN
 { 
 $$ = mm_strdup("and no chain");
}
| 
 { 
 $$=EMPTY; }
;


 ViewStmt:
 CREATE OptTemp VIEW qualified_name opt_column_list opt_reloptions AS SelectStmt opt_check_option
 { 
 $$ = cat_str(9,mm_strdup("create"),$2,mm_strdup("view"),$4,$5,$6,mm_strdup("as"),$8,$9);
}
|  CREATE OR REPLACE OptTemp VIEW qualified_name opt_column_list opt_reloptions AS SelectStmt opt_check_option
 { 
 $$ = cat_str(9,mm_strdup("create or replace"),$4,mm_strdup("view"),$6,$7,$8,mm_strdup("as"),$10,$11);
}
|  CREATE OptTemp RECURSIVE VIEW qualified_name '(' columnList ')' opt_reloptions AS SelectStmt opt_check_option
 { 
 $$ = cat_str(11,mm_strdup("create"),$2,mm_strdup("recursive view"),$5,mm_strdup("("),$7,mm_strdup(")"),$9,mm_strdup("as"),$11,$12);
}
|  CREATE OR REPLACE OptTemp RECURSIVE VIEW qualified_name '(' columnList ')' opt_reloptions AS SelectStmt opt_check_option
 { 
 $$ = cat_str(11,mm_strdup("create or replace"),$4,mm_strdup("recursive view"),$7,mm_strdup("("),$9,mm_strdup(")"),$11,mm_strdup("as"),$13,$14);
}
;


 opt_check_option:
 WITH CHECK OPTION
 { 
 $$ = mm_strdup("with check option");
}
|  WITH CASCADED CHECK OPTION
 { 
 $$ = mm_strdup("with cascaded check option");
}
|  WITH LOCAL CHECK OPTION
 { 
 $$ = mm_strdup("with local check option");
}
| 
 { 
 $$=EMPTY; }
;


 LoadStmt:
 LOAD file_name
 { 
 $$ = cat_str(2,mm_strdup("load"),$2);
}
;


 CreatedbStmt:
 CREATE DATABASE name opt_with createdb_opt_list
 { 
 $$ = cat_str(4,mm_strdup("create database"),$3,$4,$5);
}
;


 createdb_opt_list:
 createdb_opt_items
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 createdb_opt_items:
 createdb_opt_item
 { 
 $$ = $1;
}
|  createdb_opt_items createdb_opt_item
 { 
 $$ = cat_str(2,$1,$2);
}
;


 createdb_opt_item:
 createdb_opt_name opt_equal SignedIconst
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  createdb_opt_name opt_equal opt_boolean_or_string
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  createdb_opt_name opt_equal DEFAULT
 { 
 $$ = cat_str(3,$1,$2,mm_strdup("default"));
}
;


 createdb_opt_name:
 ecpg_ident
 { 
 $$ = $1;
}
|  CONNECTION LIMIT
 { 
 $$ = mm_strdup("connection limit");
}
|  ENCODING
 { 
 $$ = mm_strdup("encoding");
}
|  LOCATION
 { 
 $$ = mm_strdup("location");
}
|  OWNER
 { 
 $$ = mm_strdup("owner");
}
|  TABLESPACE
 { 
 $$ = mm_strdup("tablespace");
}
|  TEMPLATE
 { 
 $$ = mm_strdup("template");
}
;


 opt_equal:
 '='
 { 
 $$ = mm_strdup("=");
}
| 
 { 
 $$=EMPTY; }
;


 AlterDatabaseStmt:
 ALTER DATABASE name WITH createdb_opt_list
 { 
 $$ = cat_str(4,mm_strdup("alter database"),$3,mm_strdup("with"),$5);
}
|  ALTER DATABASE name createdb_opt_list
 { 
 $$ = cat_str(3,mm_strdup("alter database"),$3,$4);
}
|  ALTER DATABASE name SET TABLESPACE name
 { 
 $$ = cat_str(4,mm_strdup("alter database"),$3,mm_strdup("set tablespace"),$6);
}
;


 AlterDatabaseSetStmt:
 ALTER DATABASE name SetResetClause
 { 
 $$ = cat_str(3,mm_strdup("alter database"),$3,$4);
}
;


 DropdbStmt:
 DROP DATABASE name
 { 
 $$ = cat_str(2,mm_strdup("drop database"),$3);
}
|  DROP DATABASE IF_P EXISTS name
 { 
 $$ = cat_str(2,mm_strdup("drop database if exists"),$5);
}
|  DROP DATABASE name opt_with '(' drop_option_list ')'
 { 
 $$ = cat_str(6,mm_strdup("drop database"),$3,$4,mm_strdup("("),$6,mm_strdup(")"));
}
|  DROP DATABASE IF_P EXISTS name opt_with '(' drop_option_list ')'
 { 
 $$ = cat_str(6,mm_strdup("drop database if exists"),$5,$6,mm_strdup("("),$8,mm_strdup(")"));
}
;


 drop_option_list:
 drop_option
 { 
 $$ = $1;
}
|  drop_option_list ',' drop_option
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 drop_option:
 FORCE
 { 
 $$ = mm_strdup("force");
}
;


 AlterCollationStmt:
 ALTER COLLATION any_name REFRESH VERSION_P
 { 
 $$ = cat_str(3,mm_strdup("alter collation"),$3,mm_strdup("refresh version"));
}
;


 AlterSystemStmt:
 ALTER SYSTEM_P SET generic_set
 { 
 $$ = cat_str(2,mm_strdup("alter system set"),$4);
}
|  ALTER SYSTEM_P RESET generic_reset
 { 
 $$ = cat_str(2,mm_strdup("alter system reset"),$4);
}
;


 CreateDomainStmt:
 CREATE DOMAIN_P any_name opt_as Typename ColQualList
 { 
 $$ = cat_str(5,mm_strdup("create domain"),$3,$4,$5,$6);
}
;


 AlterDomainStmt:
 ALTER DOMAIN_P any_name alter_column_default
 { 
 $$ = cat_str(3,mm_strdup("alter domain"),$3,$4);
}
|  ALTER DOMAIN_P any_name DROP NOT NULL_P
 { 
 $$ = cat_str(3,mm_strdup("alter domain"),$3,mm_strdup("drop not null"));
}
|  ALTER DOMAIN_P any_name SET NOT NULL_P
 { 
 $$ = cat_str(3,mm_strdup("alter domain"),$3,mm_strdup("set not null"));
}
|  ALTER DOMAIN_P any_name ADD_P TableConstraint
 { 
 $$ = cat_str(4,mm_strdup("alter domain"),$3,mm_strdup("add"),$5);
}
|  ALTER DOMAIN_P any_name DROP CONSTRAINT name opt_drop_behavior
 { 
 $$ = cat_str(5,mm_strdup("alter domain"),$3,mm_strdup("drop constraint"),$6,$7);
}
|  ALTER DOMAIN_P any_name DROP CONSTRAINT IF_P EXISTS name opt_drop_behavior
 { 
 $$ = cat_str(5,mm_strdup("alter domain"),$3,mm_strdup("drop constraint if exists"),$8,$9);
}
|  ALTER DOMAIN_P any_name VALIDATE CONSTRAINT name
 { 
 $$ = cat_str(4,mm_strdup("alter domain"),$3,mm_strdup("validate constraint"),$6);
}
;


 opt_as:
 AS
 { 
 $$ = mm_strdup("as");
}
| 
 { 
 $$=EMPTY; }
;


 AlterTSDictionaryStmt:
 ALTER TEXT_P SEARCH DICTIONARY any_name definition
 { 
 $$ = cat_str(3,mm_strdup("alter text search dictionary"),$5,$6);
}
;


 AlterTSConfigurationStmt:
 ALTER TEXT_P SEARCH CONFIGURATION any_name ADD_P MAPPING FOR name_list any_with any_name_list
 { 
 $$ = cat_str(6,mm_strdup("alter text search configuration"),$5,mm_strdup("add mapping for"),$9,$10,$11);
}
|  ALTER TEXT_P SEARCH CONFIGURATION any_name ALTER MAPPING FOR name_list any_with any_name_list
 { 
 $$ = cat_str(6,mm_strdup("alter text search configuration"),$5,mm_strdup("alter mapping for"),$9,$10,$11);
}
|  ALTER TEXT_P SEARCH CONFIGURATION any_name ALTER MAPPING REPLACE any_name any_with any_name
 { 
 $$ = cat_str(6,mm_strdup("alter text search configuration"),$5,mm_strdup("alter mapping replace"),$9,$10,$11);
}
|  ALTER TEXT_P SEARCH CONFIGURATION any_name ALTER MAPPING FOR name_list REPLACE any_name any_with any_name
 { 
 $$ = cat_str(8,mm_strdup("alter text search configuration"),$5,mm_strdup("alter mapping for"),$9,mm_strdup("replace"),$11,$12,$13);
}
|  ALTER TEXT_P SEARCH CONFIGURATION any_name DROP MAPPING FOR name_list
 { 
 $$ = cat_str(4,mm_strdup("alter text search configuration"),$5,mm_strdup("drop mapping for"),$9);
}
|  ALTER TEXT_P SEARCH CONFIGURATION any_name DROP MAPPING IF_P EXISTS FOR name_list
 { 
 $$ = cat_str(4,mm_strdup("alter text search configuration"),$5,mm_strdup("drop mapping if exists for"),$11);
}
;


 any_with:
 WITH
 { 
 $$ = mm_strdup("with");
}
|  WITH_LA
 { 
 $$ = mm_strdup("with");
}
;


 CreateConversionStmt:
 CREATE opt_default CONVERSION_P any_name FOR ecpg_sconst TO ecpg_sconst FROM any_name
 { 
 $$ = cat_str(10,mm_strdup("create"),$2,mm_strdup("conversion"),$4,mm_strdup("for"),$6,mm_strdup("to"),$8,mm_strdup("from"),$10);
}
;


 ClusterStmt:
 CLUSTER opt_verbose qualified_name cluster_index_specification
 { 
 $$ = cat_str(4,mm_strdup("cluster"),$2,$3,$4);
}
|  CLUSTER '(' utility_option_list ')' qualified_name cluster_index_specification
 { 
 $$ = cat_str(5,mm_strdup("cluster ("),$3,mm_strdup(")"),$5,$6);
}
|  CLUSTER opt_verbose
 { 
 $$ = cat_str(2,mm_strdup("cluster"),$2);
}
|  CLUSTER opt_verbose name ON qualified_name
 { 
 $$ = cat_str(5,mm_strdup("cluster"),$2,$3,mm_strdup("on"),$5);
}
;


 cluster_index_specification:
 USING name
 { 
 $$ = cat_str(2,mm_strdup("using"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 VacuumStmt:
 VACUUM opt_full opt_freeze opt_verbose opt_analyze opt_vacuum_relation_list
 { 
 $$ = cat_str(6,mm_strdup("vacuum"),$2,$3,$4,$5,$6);
}
|  VACUUM '(' utility_option_list ')' opt_vacuum_relation_list
 { 
 $$ = cat_str(4,mm_strdup("vacuum ("),$3,mm_strdup(")"),$5);
}
;


 AnalyzeStmt:
 analyze_keyword opt_verbose opt_vacuum_relation_list
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  analyze_keyword '(' utility_option_list ')' opt_vacuum_relation_list
 { 
 $$ = cat_str(5,$1,mm_strdup("("),$3,mm_strdup(")"),$5);
}
;


 utility_option_list:
 utility_option_elem
 { 
 $$ = $1;
}
|  utility_option_list ',' utility_option_elem
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 analyze_keyword:
 ANALYZE
 { 
 $$ = mm_strdup("analyze");
}
|  ANALYSE
 { 
 $$ = mm_strdup("analyse");
}
;


 utility_option_elem:
 utility_option_name utility_option_arg
 { 
 $$ = cat_str(2,$1,$2);
}
;


 utility_option_name:
 NonReservedWord
 { 
 $$ = $1;
}
|  analyze_keyword
 { 
 $$ = $1;
}
;


 utility_option_arg:
 opt_boolean_or_string
 { 
 $$ = $1;
}
|  NumericOnly
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 opt_analyze:
 analyze_keyword
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 opt_verbose:
 VERBOSE
 { 
 $$ = mm_strdup("verbose");
}
| 
 { 
 $$=EMPTY; }
;


 opt_full:
 FULL
 { 
 $$ = mm_strdup("full");
}
| 
 { 
 $$=EMPTY; }
;


 opt_freeze:
 FREEZE
 { 
 $$ = mm_strdup("freeze");
}
| 
 { 
 $$=EMPTY; }
;


 opt_name_list:
 '(' name_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 vacuum_relation:
 qualified_name opt_name_list
 { 
 $$ = cat_str(2,$1,$2);
}
;


 vacuum_relation_list:
 vacuum_relation
 { 
 $$ = $1;
}
|  vacuum_relation_list ',' vacuum_relation
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 opt_vacuum_relation_list:
 vacuum_relation_list
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 ExplainStmt:
 EXPLAIN ExplainableStmt
 { 
 $$ = cat_str(2,mm_strdup("explain"),$2);
}
|  EXPLAIN analyze_keyword opt_verbose ExplainableStmt
 { 
 $$ = cat_str(4,mm_strdup("explain"),$2,$3,$4);
}
|  EXPLAIN VERBOSE ExplainableStmt
 { 
 $$ = cat_str(2,mm_strdup("explain verbose"),$3);
}
|  EXPLAIN '(' utility_option_list ')' ExplainableStmt
 { 
 $$ = cat_str(4,mm_strdup("explain ("),$3,mm_strdup(")"),$5);
}
;


 ExplainableStmt:
 SelectStmt
 { 
 $$ = $1;
}
|  InsertStmt
 { 
 $$ = $1;
}
|  UpdateStmt
 { 
 $$ = $1;
}
|  DeleteStmt
 { 
 $$ = $1;
}
|  DeclareCursorStmt
 { 
 $$ = $1;
}
|  CreateAsStmt
 { 
 $$ = $1;
}
|  CreateMatViewStmt
 { 
 $$ = $1;
}
|  RefreshMatViewStmt
 { 
 $$ = $1;
}
|  ExecuteStmt
	{
		$$ = $1.name;
	}
;


 PrepareStmt:
PREPARE prepared_name prep_type_clause AS PreparableStmt
	{
		$$.name = $2;
		$$.type = $3;
		$$.stmt = $5;
	}
	| PREPARE prepared_name FROM execstring
	{
		$$.name = $2;
		$$.type = NULL;
		$$.stmt = $4;
	}
;


 prep_type_clause:
 '(' type_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 PreparableStmt:
 SelectStmt
 { 
 $$ = $1;
}
|  InsertStmt
 { 
 $$ = $1;
}
|  UpdateStmt
 { 
 $$ = $1;
}
|  DeleteStmt
 { 
 $$ = $1;
}
;


 ExecuteStmt:
EXECUTE prepared_name execute_param_clause execute_rest
	{
		$$.name = $2;
		$$.type = $3;
	}
| CREATE OptTemp TABLE create_as_target AS EXECUTE prepared_name execute_param_clause opt_with_data execute_rest
	{
		$$.name = cat_str(8,mm_strdup("create"),$2,mm_strdup("table"),$4,mm_strdup("as execute"),$7,$8,$9);
	}
| CREATE OptTemp TABLE IF_P NOT EXISTS create_as_target AS EXECUTE prepared_name execute_param_clause opt_with_data execute_rest
	{
		$$.name = cat_str(8,mm_strdup("create"),$2,mm_strdup("table if not exists"),$7,mm_strdup("as execute"),$10,$11,$12);
	}
;


 execute_param_clause:
 '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 InsertStmt:
 opt_with_clause INSERT INTO insert_target insert_rest opt_on_conflict returning_clause
 { 
 $$ = cat_str(6,$1,mm_strdup("insert into"),$4,$5,$6,$7);
}
;


 insert_target:
 qualified_name
 { 
 $$ = $1;
}
|  qualified_name AS ColId
 { 
 $$ = cat_str(3,$1,mm_strdup("as"),$3);
}
;


 insert_rest:
 SelectStmt
 { 
 $$ = $1;
}
|  OVERRIDING override_kind VALUE_P SelectStmt
 { 
 $$ = cat_str(4,mm_strdup("overriding"),$2,mm_strdup("value"),$4);
}
|  '(' insert_column_list ')' SelectStmt
 { 
 $$ = cat_str(4,mm_strdup("("),$2,mm_strdup(")"),$4);
}
|  '(' insert_column_list ')' OVERRIDING override_kind VALUE_P SelectStmt
 { 
 $$ = cat_str(6,mm_strdup("("),$2,mm_strdup(") overriding"),$5,mm_strdup("value"),$7);
}
|  DEFAULT VALUES
 { 
 $$ = mm_strdup("default values");
}
;


 override_kind:
 USER
 { 
 $$ = mm_strdup("user");
}
|  SYSTEM_P
 { 
 $$ = mm_strdup("system");
}
;


 insert_column_list:
 insert_column_item
 { 
 $$ = $1;
}
|  insert_column_list ',' insert_column_item
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 insert_column_item:
 ColId opt_indirection
 { 
 $$ = cat_str(2,$1,$2);
}
;


 opt_on_conflict:
 ON CONFLICT opt_conf_expr DO UPDATE SET set_clause_list where_clause
 { 
 $$ = cat_str(5,mm_strdup("on conflict"),$3,mm_strdup("do update set"),$7,$8);
}
|  ON CONFLICT opt_conf_expr DO NOTHING
 { 
 $$ = cat_str(3,mm_strdup("on conflict"),$3,mm_strdup("do nothing"));
}
| 
 { 
 $$=EMPTY; }
;


 opt_conf_expr:
 '(' index_params ')' where_clause
 { 
 $$ = cat_str(4,mm_strdup("("),$2,mm_strdup(")"),$4);
}
|  ON CONSTRAINT name
 { 
 $$ = cat_str(2,mm_strdup("on constraint"),$3);
}
| 
 { 
 $$=EMPTY; }
;


 returning_clause:
RETURNING target_list opt_ecpg_into
 { 
 $$ = cat_str(2,mm_strdup("returning"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 DeleteStmt:
 opt_with_clause DELETE_P FROM relation_expr_opt_alias using_clause where_or_current_clause returning_clause
 { 
 $$ = cat_str(6,$1,mm_strdup("delete from"),$4,$5,$6,$7);
}
;


 using_clause:
 USING from_list
 { 
 $$ = cat_str(2,mm_strdup("using"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 LockStmt:
 LOCK_P opt_table relation_expr_list opt_lock opt_nowait
 { 
 $$ = cat_str(5,mm_strdup("lock"),$2,$3,$4,$5);
}
;


 opt_lock:
 IN_P lock_type MODE
 { 
 $$ = cat_str(3,mm_strdup("in"),$2,mm_strdup("mode"));
}
| 
 { 
 $$=EMPTY; }
;


 lock_type:
 ACCESS SHARE
 { 
 $$ = mm_strdup("access share");
}
|  ROW SHARE
 { 
 $$ = mm_strdup("row share");
}
|  ROW EXCLUSIVE
 { 
 $$ = mm_strdup("row exclusive");
}
|  SHARE UPDATE EXCLUSIVE
 { 
 $$ = mm_strdup("share update exclusive");
}
|  SHARE
 { 
 $$ = mm_strdup("share");
}
|  SHARE ROW EXCLUSIVE
 { 
 $$ = mm_strdup("share row exclusive");
}
|  EXCLUSIVE
 { 
 $$ = mm_strdup("exclusive");
}
|  ACCESS EXCLUSIVE
 { 
 $$ = mm_strdup("access exclusive");
}
;


 opt_nowait:
 NOWAIT
 { 
 $$ = mm_strdup("nowait");
}
| 
 { 
 $$=EMPTY; }
;


 opt_nowait_or_skip:
 NOWAIT
 { 
 $$ = mm_strdup("nowait");
}
|  SKIP LOCKED
 { 
 $$ = mm_strdup("skip locked");
}
| 
 { 
 $$=EMPTY; }
;


 UpdateStmt:
 opt_with_clause UPDATE relation_expr_opt_alias SET set_clause_list from_clause where_or_current_clause returning_clause
 { 
 $$ = cat_str(8,$1,mm_strdup("update"),$3,mm_strdup("set"),$5,$6,$7,$8);
}
;


 set_clause_list:
 set_clause
 { 
 $$ = $1;
}
|  set_clause_list ',' set_clause
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 set_clause:
 set_target '=' a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("="),$3);
}
|  '(' set_target_list ')' '=' a_expr
 { 
 $$ = cat_str(4,mm_strdup("("),$2,mm_strdup(") ="),$5);
}
;


 set_target:
 ColId opt_indirection
 { 
 $$ = cat_str(2,$1,$2);
}
;


 set_target_list:
 set_target
 { 
 $$ = $1;
}
|  set_target_list ',' set_target
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 DeclareCursorStmt:
 DECLARE cursor_name cursor_options CURSOR opt_hold FOR SelectStmt
	{
		struct cursor *ptr, *this;
		char *cursor_marker = $2[0] == ':' ? mm_strdup("$0") : mm_strdup($2);
		char *comment, *c1, *c2;
		int (* strcmp_fn)(const char *, const char *) = (($2[0] == ':' || $2[0] == '"') ? strcmp : pg_strcasecmp);

                if (INFORMIX_MODE && pg_strcasecmp($2, "database") == 0)
                        mmfatal(PARSE_ERROR, "\"database\" cannot be used as cursor name in INFORMIX mode");

		for (ptr = cur; ptr != NULL; ptr = ptr->next)
		{
			if (strcmp_fn($2, ptr->name) == 0)
			{
				if ($2[0] == ':')
					mmerror(PARSE_ERROR, ET_ERROR, "using variable \"%s\" in different declare statements is not supported", $2+1);
				else
					mmerror(PARSE_ERROR, ET_ERROR, "cursor \"%s\" is already defined", $2);
			}
		}

		this = (struct cursor *) mm_alloc(sizeof(struct cursor));

		this->next = cur;
		this->name = $2;
		this->function = (current_function ? mm_strdup(current_function) : NULL);
		this->connection = connection ? mm_strdup(connection) : NULL;
		this->opened = false;
		this->command =  cat_str(7, mm_strdup("declare"), cursor_marker, $3, mm_strdup("cursor"), $5, mm_strdup("for"), $7);
		this->argsinsert = argsinsert;
		this->argsinsert_oos = NULL;
		this->argsresult = argsresult;
		this->argsresult_oos = NULL;
		argsinsert = argsresult = NULL;
		cur = this;

		c1 = mm_strdup(this->command);
		if ((c2 = strstr(c1, "*/")) != NULL)
		{
			/* We put this text into a comment, so we better remove [*][/]. */
			c2[0] = '.';
			c2[1] = '.';
		}
		comment = cat_str(3, mm_strdup("/*"), c1, mm_strdup("*/"));

		$$ = cat2_str(adjust_outofscope_cursor_vars(this), comment);
	}
;


 cursor_name:
 name
 { 
 $$ = $1;
}
	| char_civar
		{
			char *curname = mm_alloc(strlen($1) + 2);
			sprintf(curname, ":%s", $1);
			free($1);
			$1 = curname;
			$$ = $1;
		}
;


 cursor_options:

 { 
 $$=EMPTY; }
|  cursor_options NO SCROLL
 { 
 $$ = cat_str(2,$1,mm_strdup("no scroll"));
}
|  cursor_options SCROLL
 { 
 $$ = cat_str(2,$1,mm_strdup("scroll"));
}
|  cursor_options BINARY
 { 
 $$ = cat_str(2,$1,mm_strdup("binary"));
}
|  cursor_options ASENSITIVE
 { 
 $$ = cat_str(2,$1,mm_strdup("asensitive"));
}
|  cursor_options INSENSITIVE
 { 
 $$ = cat_str(2,$1,mm_strdup("insensitive"));
}
;


 opt_hold:

	{
		if (compat == ECPG_COMPAT_INFORMIX_SE && autocommit)
			$$ = mm_strdup("with hold");
		else
			$$ = EMPTY;
	}
|  WITH HOLD
 { 
 $$ = mm_strdup("with hold");
}
|  WITHOUT HOLD
 { 
 $$ = mm_strdup("without hold");
}
;


 SelectStmt:
 select_no_parens %prec UMINUS
 { 
 $$ = $1;
}
|  select_with_parens %prec UMINUS
 { 
 $$ = $1;
}
;


 select_with_parens:
 '(' select_no_parens ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
|  '(' select_with_parens ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
;


 select_no_parens:
 simple_select
 { 
 $$ = $1;
}
|  select_clause sort_clause
 { 
 $$ = cat_str(2,$1,$2);
}
|  select_clause opt_sort_clause for_locking_clause opt_select_limit
 { 
 $$ = cat_str(4,$1,$2,$3,$4);
}
|  select_clause opt_sort_clause select_limit opt_for_locking_clause
 { 
 $$ = cat_str(4,$1,$2,$3,$4);
}
|  with_clause select_clause
 { 
 $$ = cat_str(2,$1,$2);
}
|  with_clause select_clause sort_clause
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  with_clause select_clause opt_sort_clause for_locking_clause opt_select_limit
 { 
 $$ = cat_str(5,$1,$2,$3,$4,$5);
}
|  with_clause select_clause opt_sort_clause select_limit opt_for_locking_clause
 { 
 $$ = cat_str(5,$1,$2,$3,$4,$5);
}
;


 select_clause:
 simple_select
 { 
 $$ = $1;
}
|  select_with_parens
 { 
 $$ = $1;
}
;


 simple_select:
 SELECT opt_all_clause opt_target_list into_clause from_clause where_clause group_clause having_clause window_clause
 { 
 $$ = cat_str(9,mm_strdup("select"),$2,$3,$4,$5,$6,$7,$8,$9);
}
|  SELECT distinct_clause target_list into_clause from_clause where_clause group_clause having_clause window_clause
 { 
 $$ = cat_str(9,mm_strdup("select"),$2,$3,$4,$5,$6,$7,$8,$9);
}
|  values_clause
 { 
 $$ = $1;
}
|  TABLE relation_expr
 { 
 $$ = cat_str(2,mm_strdup("table"),$2);
}
|  select_clause UNION set_quantifier select_clause
 { 
 $$ = cat_str(4,$1,mm_strdup("union"),$3,$4);
}
|  select_clause INTERSECT set_quantifier select_clause
 { 
 $$ = cat_str(4,$1,mm_strdup("intersect"),$3,$4);
}
|  select_clause EXCEPT set_quantifier select_clause
 { 
 $$ = cat_str(4,$1,mm_strdup("except"),$3,$4);
}
;


 with_clause:
 WITH cte_list
 { 
 $$ = cat_str(2,mm_strdup("with"),$2);
}
|  WITH_LA cte_list
 { 
 $$ = cat_str(2,mm_strdup("with"),$2);
}
|  WITH RECURSIVE cte_list
 { 
 $$ = cat_str(2,mm_strdup("with recursive"),$3);
}
;


 cte_list:
 common_table_expr
 { 
 $$ = $1;
}
|  cte_list ',' common_table_expr
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 common_table_expr:
 name opt_name_list AS opt_materialized '(' PreparableStmt ')' opt_search_clause opt_cycle_clause
 { 
 $$ = cat_str(9,$1,$2,mm_strdup("as"),$4,mm_strdup("("),$6,mm_strdup(")"),$8,$9);
}
;


 opt_materialized:
 MATERIALIZED
 { 
 $$ = mm_strdup("materialized");
}
|  NOT MATERIALIZED
 { 
 $$ = mm_strdup("not materialized");
}
| 
 { 
 $$=EMPTY; }
;


 opt_search_clause:
 SEARCH DEPTH FIRST_P BY columnList SET ColId
 { 
 $$ = cat_str(4,mm_strdup("search depth first by"),$5,mm_strdup("set"),$7);
}
|  SEARCH BREADTH FIRST_P BY columnList SET ColId
 { 
 $$ = cat_str(4,mm_strdup("search breadth first by"),$5,mm_strdup("set"),$7);
}
| 
 { 
 $$=EMPTY; }
;


 opt_cycle_clause:
 CYCLE columnList SET ColId TO AexprConst DEFAULT AexprConst USING ColId
 { 
 $$ = cat_str(10,mm_strdup("cycle"),$2,mm_strdup("set"),$4,mm_strdup("to"),$6,mm_strdup("default"),$8,mm_strdup("using"),$10);
}
|  CYCLE columnList SET ColId USING ColId
 { 
 $$ = cat_str(6,mm_strdup("cycle"),$2,mm_strdup("set"),$4,mm_strdup("using"),$6);
}
| 
 { 
 $$=EMPTY; }
;


 opt_with_clause:
 with_clause
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 into_clause:
 INTO OptTempTableName
					{
						FoundInto = 1;
						$$= cat2_str(mm_strdup("into"), $2);
					}
	| ecpg_into { $$ = EMPTY; }
| 
 { 
 $$=EMPTY; }
;


 OptTempTableName:
 TEMPORARY opt_table qualified_name
 { 
 $$ = cat_str(3,mm_strdup("temporary"),$2,$3);
}
|  TEMP opt_table qualified_name
 { 
 $$ = cat_str(3,mm_strdup("temp"),$2,$3);
}
|  LOCAL TEMPORARY opt_table qualified_name
 { 
 $$ = cat_str(3,mm_strdup("local temporary"),$3,$4);
}
|  LOCAL TEMP opt_table qualified_name
 { 
 $$ = cat_str(3,mm_strdup("local temp"),$3,$4);
}
|  GLOBAL TEMPORARY opt_table qualified_name
 { 
 $$ = cat_str(3,mm_strdup("global temporary"),$3,$4);
}
|  GLOBAL TEMP opt_table qualified_name
 { 
 $$ = cat_str(3,mm_strdup("global temp"),$3,$4);
}
|  UNLOGGED opt_table qualified_name
 { 
 $$ = cat_str(3,mm_strdup("unlogged"),$2,$3);
}
|  TABLE qualified_name
 { 
 $$ = cat_str(2,mm_strdup("table"),$2);
}
|  qualified_name
 { 
 $$ = $1;
}
;


 opt_table:
 TABLE
 { 
 $$ = mm_strdup("table");
}
| 
 { 
 $$=EMPTY; }
;


 set_quantifier:
 ALL
 { 
 $$ = mm_strdup("all");
}
|  DISTINCT
 { 
 $$ = mm_strdup("distinct");
}
| 
 { 
 $$=EMPTY; }
;


 distinct_clause:
 DISTINCT
 { 
 $$ = mm_strdup("distinct");
}
|  DISTINCT ON '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("distinct on ("),$4,mm_strdup(")"));
}
;


 opt_all_clause:
 ALL
 { 
 $$ = mm_strdup("all");
}
| 
 { 
 $$=EMPTY; }
;


 opt_sort_clause:
 sort_clause
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 sort_clause:
 ORDER BY sortby_list
 { 
 $$ = cat_str(2,mm_strdup("order by"),$3);
}
;


 sortby_list:
 sortby
 { 
 $$ = $1;
}
|  sortby_list ',' sortby
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 sortby:
 a_expr USING qual_all_Op opt_nulls_order
 { 
 $$ = cat_str(4,$1,mm_strdup("using"),$3,$4);
}
|  a_expr opt_asc_desc opt_nulls_order
 { 
 $$ = cat_str(3,$1,$2,$3);
}
;


 select_limit:
 limit_clause offset_clause
 { 
 $$ = cat_str(2,$1,$2);
}
|  offset_clause limit_clause
 { 
 $$ = cat_str(2,$1,$2);
}
|  limit_clause
 { 
 $$ = $1;
}
|  offset_clause
 { 
 $$ = $1;
}
;


 opt_select_limit:
 select_limit
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 limit_clause:
 LIMIT select_limit_value
 { 
 $$ = cat_str(2,mm_strdup("limit"),$2);
}
|  LIMIT select_limit_value ',' select_offset_value
	{
		mmerror(PARSE_ERROR, ET_WARNING, "no longer supported LIMIT #,# syntax passed to server");
		$$ = cat_str(4, mm_strdup("limit"), $2, mm_strdup(","), $4);
	}
|  FETCH first_or_next select_fetch_first_value row_or_rows ONLY
 { 
 $$ = cat_str(5,mm_strdup("fetch"),$2,$3,$4,mm_strdup("only"));
}
|  FETCH first_or_next select_fetch_first_value row_or_rows WITH TIES
 { 
 $$ = cat_str(5,mm_strdup("fetch"),$2,$3,$4,mm_strdup("with ties"));
}
|  FETCH first_or_next row_or_rows ONLY
 { 
 $$ = cat_str(4,mm_strdup("fetch"),$2,$3,mm_strdup("only"));
}
|  FETCH first_or_next row_or_rows WITH TIES
 { 
 $$ = cat_str(4,mm_strdup("fetch"),$2,$3,mm_strdup("with ties"));
}
;


 offset_clause:
 OFFSET select_offset_value
 { 
 $$ = cat_str(2,mm_strdup("offset"),$2);
}
|  OFFSET select_fetch_first_value row_or_rows
 { 
 $$ = cat_str(3,mm_strdup("offset"),$2,$3);
}
;


 select_limit_value:
 a_expr
 { 
 $$ = $1;
}
|  ALL
 { 
 $$ = mm_strdup("all");
}
;


 select_offset_value:
 a_expr
 { 
 $$ = $1;
}
;


 select_fetch_first_value:
 c_expr
 { 
 $$ = $1;
}
|  '+' I_or_F_const
 { 
 $$ = cat_str(2,mm_strdup("+"),$2);
}
|  '-' I_or_F_const
 { 
 $$ = cat_str(2,mm_strdup("-"),$2);
}
;


 I_or_F_const:
 Iconst
 { 
 $$ = $1;
}
|  ecpg_fconst
 { 
 $$ = $1;
}
;


 row_or_rows:
 ROW
 { 
 $$ = mm_strdup("row");
}
|  ROWS
 { 
 $$ = mm_strdup("rows");
}
;


 first_or_next:
 FIRST_P
 { 
 $$ = mm_strdup("first");
}
|  NEXT
 { 
 $$ = mm_strdup("next");
}
;


 group_clause:
 GROUP_P BY set_quantifier group_by_list
 { 
 $$ = cat_str(3,mm_strdup("group by"),$3,$4);
}
| 
 { 
 $$=EMPTY; }
;


 group_by_list:
 group_by_item
 { 
 $$ = $1;
}
|  group_by_list ',' group_by_item
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 group_by_item:
 a_expr
 { 
 $$ = $1;
}
|  empty_grouping_set
 { 
 $$ = $1;
}
|  cube_clause
 { 
 $$ = $1;
}
|  rollup_clause
 { 
 $$ = $1;
}
|  grouping_sets_clause
 { 
 $$ = $1;
}
;


 empty_grouping_set:
 '(' ')'
 { 
 $$ = mm_strdup("( )");
}
;


 rollup_clause:
 ROLLUP '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("rollup ("),$3,mm_strdup(")"));
}
;


 cube_clause:
 CUBE '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("cube ("),$3,mm_strdup(")"));
}
;


 grouping_sets_clause:
 GROUPING SETS '(' group_by_list ')'
 { 
 $$ = cat_str(3,mm_strdup("grouping sets ("),$4,mm_strdup(")"));
}
;


 having_clause:
 HAVING a_expr
 { 
 $$ = cat_str(2,mm_strdup("having"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 for_locking_clause:
 for_locking_items
 { 
 $$ = $1;
}
|  FOR READ ONLY
 { 
 $$ = mm_strdup("for read only");
}
;


 opt_for_locking_clause:
 for_locking_clause
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 for_locking_items:
 for_locking_item
 { 
 $$ = $1;
}
|  for_locking_items for_locking_item
 { 
 $$ = cat_str(2,$1,$2);
}
;


 for_locking_item:
 for_locking_strength locked_rels_list opt_nowait_or_skip
 { 
 $$ = cat_str(3,$1,$2,$3);
}
;


 for_locking_strength:
 FOR UPDATE
 { 
 $$ = mm_strdup("for update");
}
|  FOR NO KEY UPDATE
 { 
 $$ = mm_strdup("for no key update");
}
|  FOR SHARE
 { 
 $$ = mm_strdup("for share");
}
|  FOR KEY SHARE
 { 
 $$ = mm_strdup("for key share");
}
;


 locked_rels_list:
 OF qualified_name_list
 { 
 $$ = cat_str(2,mm_strdup("of"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 values_clause:
 VALUES '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("values ("),$3,mm_strdup(")"));
}
|  values_clause ',' '(' expr_list ')'
 { 
 $$ = cat_str(4,$1,mm_strdup(", ("),$4,mm_strdup(")"));
}
;


 from_clause:
 FROM from_list
 { 
 $$ = cat_str(2,mm_strdup("from"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 from_list:
 table_ref
 { 
 $$ = $1;
}
|  from_list ',' table_ref
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 table_ref:
 relation_expr opt_alias_clause
 { 
 $$ = cat_str(2,$1,$2);
}
|  relation_expr opt_alias_clause tablesample_clause
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  func_table func_alias_clause
 { 
 $$ = cat_str(2,$1,$2);
}
|  LATERAL_P func_table func_alias_clause
 { 
 $$ = cat_str(3,mm_strdup("lateral"),$2,$3);
}
|  xmltable opt_alias_clause
 { 
 $$ = cat_str(2,$1,$2);
}
|  LATERAL_P xmltable opt_alias_clause
 { 
 $$ = cat_str(3,mm_strdup("lateral"),$2,$3);
}
|  select_with_parens opt_alias_clause
 { 
	if ($2 == NULL)
		mmerror(PARSE_ERROR, ET_ERROR, "subquery in FROM must have an alias");

 $$ = cat_str(2,$1,$2);
}
|  LATERAL_P select_with_parens opt_alias_clause
 { 
	if ($3 == NULL)
		mmerror(PARSE_ERROR, ET_ERROR, "subquery in FROM must have an alias");

 $$ = cat_str(3,mm_strdup("lateral"),$2,$3);
}
|  joined_table
 { 
 $$ = $1;
}
|  '(' joined_table ')' alias_clause
 { 
 $$ = cat_str(4,mm_strdup("("),$2,mm_strdup(")"),$4);
}
;


 joined_table:
 '(' joined_table ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
|  table_ref CROSS JOIN table_ref
 { 
 $$ = cat_str(3,$1,mm_strdup("cross join"),$4);
}
|  table_ref join_type JOIN table_ref join_qual
 { 
 $$ = cat_str(5,$1,$2,mm_strdup("join"),$4,$5);
}
|  table_ref JOIN table_ref join_qual
 { 
 $$ = cat_str(4,$1,mm_strdup("join"),$3,$4);
}
|  table_ref NATURAL join_type JOIN table_ref
 { 
 $$ = cat_str(5,$1,mm_strdup("natural"),$3,mm_strdup("join"),$5);
}
|  table_ref NATURAL JOIN table_ref
 { 
 $$ = cat_str(3,$1,mm_strdup("natural join"),$4);
}
;


 alias_clause:
 AS ColId '(' name_list ')'
 { 
 $$ = cat_str(5,mm_strdup("as"),$2,mm_strdup("("),$4,mm_strdup(")"));
}
|  AS ColId
 { 
 $$ = cat_str(2,mm_strdup("as"),$2);
}
|  ColId '(' name_list ')'
 { 
 $$ = cat_str(4,$1,mm_strdup("("),$3,mm_strdup(")"));
}
|  ColId
 { 
 $$ = $1;
}
;


 opt_alias_clause:
 alias_clause
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 opt_alias_clause_for_join_using:
 AS ColId
 { 
 $$ = cat_str(2,mm_strdup("as"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 func_alias_clause:
 alias_clause
 { 
 $$ = $1;
}
|  AS '(' TableFuncElementList ')'
 { 
 $$ = cat_str(3,mm_strdup("as ("),$3,mm_strdup(")"));
}
|  AS ColId '(' TableFuncElementList ')'
 { 
 $$ = cat_str(5,mm_strdup("as"),$2,mm_strdup("("),$4,mm_strdup(")"));
}
|  ColId '(' TableFuncElementList ')'
 { 
 $$ = cat_str(4,$1,mm_strdup("("),$3,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 join_type:
 FULL opt_outer
 { 
 $$ = cat_str(2,mm_strdup("full"),$2);
}
|  LEFT opt_outer
 { 
 $$ = cat_str(2,mm_strdup("left"),$2);
}
|  RIGHT opt_outer
 { 
 $$ = cat_str(2,mm_strdup("right"),$2);
}
|  INNER_P
 { 
 $$ = mm_strdup("inner");
}
;


 opt_outer:
 OUTER_P
 { 
 $$ = mm_strdup("outer");
}
| 
 { 
 $$=EMPTY; }
;


 join_qual:
 USING '(' name_list ')' opt_alias_clause_for_join_using
 { 
 $$ = cat_str(4,mm_strdup("using ("),$3,mm_strdup(")"),$5);
}
|  ON a_expr
 { 
 $$ = cat_str(2,mm_strdup("on"),$2);
}
;


 relation_expr:
 qualified_name
 { 
 $$ = $1;
}
|  qualified_name '*'
 { 
 $$ = cat_str(2,$1,mm_strdup("*"));
}
|  ONLY qualified_name
 { 
 $$ = cat_str(2,mm_strdup("only"),$2);
}
|  ONLY '(' qualified_name ')'
 { 
 $$ = cat_str(3,mm_strdup("only ("),$3,mm_strdup(")"));
}
;


 relation_expr_list:
 relation_expr
 { 
 $$ = $1;
}
|  relation_expr_list ',' relation_expr
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 relation_expr_opt_alias:
 relation_expr %prec UMINUS
 { 
 $$ = $1;
}
|  relation_expr ColId
 { 
 $$ = cat_str(2,$1,$2);
}
|  relation_expr AS ColId
 { 
 $$ = cat_str(3,$1,mm_strdup("as"),$3);
}
;


 tablesample_clause:
 TABLESAMPLE func_name '(' expr_list ')' opt_repeatable_clause
 { 
 $$ = cat_str(6,mm_strdup("tablesample"),$2,mm_strdup("("),$4,mm_strdup(")"),$6);
}
;


 opt_repeatable_clause:
 REPEATABLE '(' a_expr ')'
 { 
 $$ = cat_str(3,mm_strdup("repeatable ("),$3,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 func_table:
 func_expr_windowless opt_ordinality
 { 
 $$ = cat_str(2,$1,$2);
}
|  ROWS FROM '(' rowsfrom_list ')' opt_ordinality
 { 
 $$ = cat_str(4,mm_strdup("rows from ("),$4,mm_strdup(")"),$6);
}
;


 rowsfrom_item:
 func_expr_windowless opt_col_def_list
 { 
 $$ = cat_str(2,$1,$2);
}
;


 rowsfrom_list:
 rowsfrom_item
 { 
 $$ = $1;
}
|  rowsfrom_list ',' rowsfrom_item
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 opt_col_def_list:
 AS '(' TableFuncElementList ')'
 { 
 $$ = cat_str(3,mm_strdup("as ("),$3,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 opt_ordinality:
 WITH_LA ORDINALITY
 { 
 $$ = mm_strdup("with ordinality");
}
| 
 { 
 $$=EMPTY; }
;


 where_clause:
 WHERE a_expr
 { 
 $$ = cat_str(2,mm_strdup("where"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 where_or_current_clause:
 WHERE a_expr
 { 
 $$ = cat_str(2,mm_strdup("where"),$2);
}
|  WHERE CURRENT_P OF cursor_name
	{
		char *cursor_marker = $4[0] == ':' ? mm_strdup("$0") : $4;
		$$ = cat_str(2,mm_strdup("where current of"), cursor_marker);
	}
| 
 { 
 $$=EMPTY; }
;


 OptTableFuncElementList:
 TableFuncElementList
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 TableFuncElementList:
 TableFuncElement
 { 
 $$ = $1;
}
|  TableFuncElementList ',' TableFuncElement
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 TableFuncElement:
 ColId Typename opt_collate_clause
 { 
 $$ = cat_str(3,$1,$2,$3);
}
;


 xmltable:
 XMLTABLE '(' c_expr xmlexists_argument COLUMNS xmltable_column_list ')'
 { 
 $$ = cat_str(6,mm_strdup("xmltable ("),$3,$4,mm_strdup("columns"),$6,mm_strdup(")"));
}
|  XMLTABLE '(' XMLNAMESPACES '(' xml_namespace_list ')' ',' c_expr xmlexists_argument COLUMNS xmltable_column_list ')'
 { 
 $$ = cat_str(8,mm_strdup("xmltable ( xmlnamespaces ("),$5,mm_strdup(") ,"),$8,$9,mm_strdup("columns"),$11,mm_strdup(")"));
}
;


 xmltable_column_list:
 xmltable_column_el
 { 
 $$ = $1;
}
|  xmltable_column_list ',' xmltable_column_el
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 xmltable_column_el:
 ColId Typename
 { 
 $$ = cat_str(2,$1,$2);
}
|  ColId Typename xmltable_column_option_list
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  ColId FOR ORDINALITY
 { 
 $$ = cat_str(2,$1,mm_strdup("for ordinality"));
}
;


 xmltable_column_option_list:
 xmltable_column_option_el
 { 
 $$ = $1;
}
|  xmltable_column_option_list xmltable_column_option_el
 { 
 $$ = cat_str(2,$1,$2);
}
;


 xmltable_column_option_el:
 ecpg_ident b_expr
 { 
 $$ = cat_str(2,$1,$2);
}
|  DEFAULT b_expr
 { 
 $$ = cat_str(2,mm_strdup("default"),$2);
}
|  NOT NULL_P
 { 
 $$ = mm_strdup("not null");
}
|  NULL_P
 { 
 $$ = mm_strdup("null");
}
;


 xml_namespace_list:
 xml_namespace_el
 { 
 $$ = $1;
}
|  xml_namespace_list ',' xml_namespace_el
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 xml_namespace_el:
 b_expr AS ColLabel
 { 
 $$ = cat_str(3,$1,mm_strdup("as"),$3);
}
|  DEFAULT b_expr
 { 
 $$ = cat_str(2,mm_strdup("default"),$2);
}
;


 Typename:
 SimpleTypename opt_array_bounds
	{	$$ = cat2_str($1, $2.str); }
|  SETOF SimpleTypename opt_array_bounds
	{	$$ = cat_str(3, mm_strdup("setof"), $2, $3.str); }
|  SimpleTypename ARRAY '[' Iconst ']'
 { 
 $$ = cat_str(4,$1,mm_strdup("array ["),$4,mm_strdup("]"));
}
|  SETOF SimpleTypename ARRAY '[' Iconst ']'
 { 
 $$ = cat_str(5,mm_strdup("setof"),$2,mm_strdup("array ["),$5,mm_strdup("]"));
}
|  SimpleTypename ARRAY
 { 
 $$ = cat_str(2,$1,mm_strdup("array"));
}
|  SETOF SimpleTypename ARRAY
 { 
 $$ = cat_str(3,mm_strdup("setof"),$2,mm_strdup("array"));
}
;


 opt_array_bounds:
 opt_array_bounds '[' ']'
	{
		$$.index1 = $1.index1;
		$$.index2 = $1.index2;
		if (strcmp($$.index1, "-1") == 0)
			$$.index1 = mm_strdup("0");
		else if (strcmp($1.index2, "-1") == 0)
			$$.index2 = mm_strdup("0");
		$$.str = cat_str(2, $1.str, mm_strdup("[]"));
	}
	| opt_array_bounds '[' Iresult ']'
	{
		$$.index1 = $1.index1;
		$$.index2 = $1.index2;
		if (strcmp($1.index1, "-1") == 0)
			$$.index1 = mm_strdup($3);
		else if (strcmp($1.index2, "-1") == 0)
			$$.index2 = mm_strdup($3);
		$$.str = cat_str(4, $1.str, mm_strdup("["), $3, mm_strdup("]"));
	}
| 
	{
		$$.index1 = mm_strdup("-1");
		$$.index2 = mm_strdup("-1");
		$$.str= EMPTY;
	}
;


 SimpleTypename:
 GenericType
 { 
 $$ = $1;
}
|  Numeric
 { 
 $$ = $1;
}
|  Bit
 { 
 $$ = $1;
}
|  Character
 { 
 $$ = $1;
}
|  ConstDatetime
 { 
 $$ = $1;
}
|  ConstInterval opt_interval
 { 
 $$ = cat_str(2,$1,$2);
}
|  ConstInterval '(' Iconst ')'
 { 
 $$ = cat_str(4,$1,mm_strdup("("),$3,mm_strdup(")"));
}
;


 ConstTypename:
 Numeric
 { 
 $$ = $1;
}
|  ConstBit
 { 
 $$ = $1;
}
|  ConstCharacter
 { 
 $$ = $1;
}
|  ConstDatetime
 { 
 $$ = $1;
}
;


 GenericType:
 type_function_name opt_type_modifiers
 { 
 $$ = cat_str(2,$1,$2);
}
|  type_function_name attrs opt_type_modifiers
 { 
 $$ = cat_str(3,$1,$2,$3);
}
;


 opt_type_modifiers:
 '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 Numeric:
 INT_P
 { 
 $$ = mm_strdup("int");
}
|  INTEGER
 { 
 $$ = mm_strdup("integer");
}
|  SMALLINT
 { 
 $$ = mm_strdup("smallint");
}
|  BIGINT
 { 
 $$ = mm_strdup("bigint");
}
|  REAL
 { 
 $$ = mm_strdup("real");
}
|  FLOAT_P opt_float
 { 
 $$ = cat_str(2,mm_strdup("float"),$2);
}
|  DOUBLE_P PRECISION
 { 
 $$ = mm_strdup("double precision");
}
|  DECIMAL_P opt_type_modifiers
 { 
 $$ = cat_str(2,mm_strdup("decimal"),$2);
}
|  DEC opt_type_modifiers
 { 
 $$ = cat_str(2,mm_strdup("dec"),$2);
}
|  NUMERIC opt_type_modifiers
 { 
 $$ = cat_str(2,mm_strdup("numeric"),$2);
}
|  BOOLEAN_P
 { 
 $$ = mm_strdup("boolean");
}
;


 opt_float:
 '(' Iconst ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 Bit:
 BitWithLength
 { 
 $$ = $1;
}
|  BitWithoutLength
 { 
 $$ = $1;
}
;


 ConstBit:
 BitWithLength
 { 
 $$ = $1;
}
|  BitWithoutLength
 { 
 $$ = $1;
}
;


 BitWithLength:
 BIT opt_varying '(' expr_list ')'
 { 
 $$ = cat_str(5,mm_strdup("bit"),$2,mm_strdup("("),$4,mm_strdup(")"));
}
;


 BitWithoutLength:
 BIT opt_varying
 { 
 $$ = cat_str(2,mm_strdup("bit"),$2);
}
;


 Character:
 CharacterWithLength
 { 
 $$ = $1;
}
|  CharacterWithoutLength
 { 
 $$ = $1;
}
;


 ConstCharacter:
 CharacterWithLength
 { 
 $$ = $1;
}
|  CharacterWithoutLength
 { 
 $$ = $1;
}
;


 CharacterWithLength:
 character '(' Iconst ')'
 { 
 $$ = cat_str(4,$1,mm_strdup("("),$3,mm_strdup(")"));
}
;


 CharacterWithoutLength:
 character
 { 
 $$ = $1;
}
;


 character:
 CHARACTER opt_varying
 { 
 $$ = cat_str(2,mm_strdup("character"),$2);
}
|  CHAR_P opt_varying
 { 
 $$ = cat_str(2,mm_strdup("char"),$2);
}
|  VARCHAR
 { 
 $$ = mm_strdup("varchar");
}
|  NATIONAL CHARACTER opt_varying
 { 
 $$ = cat_str(2,mm_strdup("national character"),$3);
}
|  NATIONAL CHAR_P opt_varying
 { 
 $$ = cat_str(2,mm_strdup("national char"),$3);
}
|  NCHAR opt_varying
 { 
 $$ = cat_str(2,mm_strdup("nchar"),$2);
}
;


 opt_varying:
 VARYING
 { 
 $$ = mm_strdup("varying");
}
| 
 { 
 $$=EMPTY; }
;


 ConstDatetime:
 TIMESTAMP '(' Iconst ')' opt_timezone
 { 
 $$ = cat_str(4,mm_strdup("timestamp ("),$3,mm_strdup(")"),$5);
}
|  TIMESTAMP opt_timezone
 { 
 $$ = cat_str(2,mm_strdup("timestamp"),$2);
}
|  TIME '(' Iconst ')' opt_timezone
 { 
 $$ = cat_str(4,mm_strdup("time ("),$3,mm_strdup(")"),$5);
}
|  TIME opt_timezone
 { 
 $$ = cat_str(2,mm_strdup("time"),$2);
}
;


 ConstInterval:
 INTERVAL
 { 
 $$ = mm_strdup("interval");
}
;


 opt_timezone:
 WITH_LA TIME ZONE
 { 
 $$ = mm_strdup("with time zone");
}
|  WITHOUT TIME ZONE
 { 
 $$ = mm_strdup("without time zone");
}
| 
 { 
 $$=EMPTY; }
;


 opt_interval:
 YEAR_P
 { 
 $$ = mm_strdup("year");
}
|  MONTH_P
 { 
 $$ = mm_strdup("month");
}
|  DAY_P
 { 
 $$ = mm_strdup("day");
}
|  HOUR_P
 { 
 $$ = mm_strdup("hour");
}
|  MINUTE_P
 { 
 $$ = mm_strdup("minute");
}
|  interval_second
 { 
 $$ = $1;
}
|  YEAR_P TO MONTH_P
 { 
 $$ = mm_strdup("year to month");
}
|  DAY_P TO HOUR_P
 { 
 $$ = mm_strdup("day to hour");
}
|  DAY_P TO MINUTE_P
 { 
 $$ = mm_strdup("day to minute");
}
|  DAY_P TO interval_second
 { 
 $$ = cat_str(2,mm_strdup("day to"),$3);
}
|  HOUR_P TO MINUTE_P
 { 
 $$ = mm_strdup("hour to minute");
}
|  HOUR_P TO interval_second
 { 
 $$ = cat_str(2,mm_strdup("hour to"),$3);
}
|  MINUTE_P TO interval_second
 { 
 $$ = cat_str(2,mm_strdup("minute to"),$3);
}
| 
 { 
 $$=EMPTY; }
;


 interval_second:
 SECOND_P
 { 
 $$ = mm_strdup("second");
}
|  SECOND_P '(' Iconst ')'
 { 
 $$ = cat_str(3,mm_strdup("second ("),$3,mm_strdup(")"));
}
;


 a_expr:
 c_expr
 { 
 $$ = $1;
}
|  a_expr TYPECAST Typename
 { 
 $$ = cat_str(3,$1,mm_strdup("::"),$3);
}
|  a_expr COLLATE any_name
 { 
 $$ = cat_str(3,$1,mm_strdup("collate"),$3);
}
|  a_expr AT TIME ZONE a_expr %prec AT
 { 
 $$ = cat_str(3,$1,mm_strdup("at time zone"),$5);
}
|  '+' a_expr %prec UMINUS
 { 
 $$ = cat_str(2,mm_strdup("+"),$2);
}
|  '-' a_expr %prec UMINUS
 { 
 $$ = cat_str(2,mm_strdup("-"),$2);
}
|  a_expr '+' a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("+"),$3);
}
|  a_expr '-' a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("-"),$3);
}
|  a_expr '*' a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("*"),$3);
}
|  a_expr '/' a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("/"),$3);
}
|  a_expr '%' a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("%"),$3);
}
|  a_expr '^' a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("^"),$3);
}
|  a_expr '<' a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("<"),$3);
}
|  a_expr '>' a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup(">"),$3);
}
|  a_expr '=' a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("="),$3);
}
|  a_expr LESS_EQUALS a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("<="),$3);
}
|  a_expr GREATER_EQUALS a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup(">="),$3);
}
|  a_expr NOT_EQUALS a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("<>"),$3);
}
|  a_expr qual_Op a_expr %prec Op
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  qual_Op a_expr %prec Op
 { 
 $$ = cat_str(2,$1,$2);
}
|  a_expr AND a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("and"),$3);
}
|  a_expr OR a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("or"),$3);
}
|  NOT a_expr
 { 
 $$ = cat_str(2,mm_strdup("not"),$2);
}
|  NOT_LA a_expr %prec NOT
 { 
 $$ = cat_str(2,mm_strdup("not"),$2);
}
|  a_expr LIKE a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("like"),$3);
}
|  a_expr LIKE a_expr ESCAPE a_expr %prec LIKE
 { 
 $$ = cat_str(5,$1,mm_strdup("like"),$3,mm_strdup("escape"),$5);
}
|  a_expr NOT_LA LIKE a_expr %prec NOT_LA
 { 
 $$ = cat_str(3,$1,mm_strdup("not like"),$4);
}
|  a_expr NOT_LA LIKE a_expr ESCAPE a_expr %prec NOT_LA
 { 
 $$ = cat_str(5,$1,mm_strdup("not like"),$4,mm_strdup("escape"),$6);
}
|  a_expr ILIKE a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("ilike"),$3);
}
|  a_expr ILIKE a_expr ESCAPE a_expr %prec ILIKE
 { 
 $$ = cat_str(5,$1,mm_strdup("ilike"),$3,mm_strdup("escape"),$5);
}
|  a_expr NOT_LA ILIKE a_expr %prec NOT_LA
 { 
 $$ = cat_str(3,$1,mm_strdup("not ilike"),$4);
}
|  a_expr NOT_LA ILIKE a_expr ESCAPE a_expr %prec NOT_LA
 { 
 $$ = cat_str(5,$1,mm_strdup("not ilike"),$4,mm_strdup("escape"),$6);
}
|  a_expr SIMILAR TO a_expr %prec SIMILAR
 { 
 $$ = cat_str(3,$1,mm_strdup("similar to"),$4);
}
|  a_expr SIMILAR TO a_expr ESCAPE a_expr %prec SIMILAR
 { 
 $$ = cat_str(5,$1,mm_strdup("similar to"),$4,mm_strdup("escape"),$6);
}
|  a_expr NOT_LA SIMILAR TO a_expr %prec NOT_LA
 { 
 $$ = cat_str(3,$1,mm_strdup("not similar to"),$5);
}
|  a_expr NOT_LA SIMILAR TO a_expr ESCAPE a_expr %prec NOT_LA
 { 
 $$ = cat_str(5,$1,mm_strdup("not similar to"),$5,mm_strdup("escape"),$7);
}
|  a_expr IS NULL_P %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is null"));
}
|  a_expr ISNULL
 { 
 $$ = cat_str(2,$1,mm_strdup("isnull"));
}
|  a_expr IS NOT NULL_P %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is not null"));
}
|  a_expr NOTNULL
 { 
 $$ = cat_str(2,$1,mm_strdup("notnull"));
}
|  row OVERLAPS row
 { 
 $$ = cat_str(3,$1,mm_strdup("overlaps"),$3);
}
|  a_expr IS TRUE_P %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is true"));
}
|  a_expr IS NOT TRUE_P %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is not true"));
}
|  a_expr IS FALSE_P %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is false"));
}
|  a_expr IS NOT FALSE_P %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is not false"));
}
|  a_expr IS UNKNOWN %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is unknown"));
}
|  a_expr IS NOT UNKNOWN %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is not unknown"));
}
|  a_expr IS DISTINCT FROM a_expr %prec IS
 { 
 $$ = cat_str(3,$1,mm_strdup("is distinct from"),$5);
}
|  a_expr IS NOT DISTINCT FROM a_expr %prec IS
 { 
 $$ = cat_str(3,$1,mm_strdup("is not distinct from"),$6);
}
|  a_expr BETWEEN opt_asymmetric b_expr AND a_expr %prec BETWEEN
 { 
 $$ = cat_str(6,$1,mm_strdup("between"),$3,$4,mm_strdup("and"),$6);
}
|  a_expr NOT_LA BETWEEN opt_asymmetric b_expr AND a_expr %prec NOT_LA
 { 
 $$ = cat_str(6,$1,mm_strdup("not between"),$4,$5,mm_strdup("and"),$7);
}
|  a_expr BETWEEN SYMMETRIC b_expr AND a_expr %prec BETWEEN
 { 
 $$ = cat_str(5,$1,mm_strdup("between symmetric"),$4,mm_strdup("and"),$6);
}
|  a_expr NOT_LA BETWEEN SYMMETRIC b_expr AND a_expr %prec NOT_LA
 { 
 $$ = cat_str(5,$1,mm_strdup("not between symmetric"),$5,mm_strdup("and"),$7);
}
|  a_expr IN_P in_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("in"),$3);
}
|  a_expr NOT_LA IN_P in_expr %prec NOT_LA
 { 
 $$ = cat_str(3,$1,mm_strdup("not in"),$4);
}
|  a_expr subquery_Op sub_type select_with_parens %prec Op
 { 
 $$ = cat_str(4,$1,$2,$3,$4);
}
|  a_expr subquery_Op sub_type '(' a_expr ')' %prec Op
 { 
 $$ = cat_str(6,$1,$2,$3,mm_strdup("("),$5,mm_strdup(")"));
}
|  UNIQUE select_with_parens
 { 
mmerror(PARSE_ERROR, ET_WARNING, "unsupported feature will be passed to server");
 $$ = cat_str(2,mm_strdup("unique"),$2);
}
|  a_expr IS DOCUMENT_P %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is document"));
}
|  a_expr IS NOT DOCUMENT_P %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is not document"));
}
|  a_expr IS NORMALIZED %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is normalized"));
}
|  a_expr IS unicode_normal_form NORMALIZED %prec IS
 { 
 $$ = cat_str(4,$1,mm_strdup("is"),$3,mm_strdup("normalized"));
}
|  a_expr IS NOT NORMALIZED %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is not normalized"));
}
|  a_expr IS NOT unicode_normal_form NORMALIZED %prec IS
 { 
 $$ = cat_str(4,$1,mm_strdup("is not"),$4,mm_strdup("normalized"));
}
|  DEFAULT
 { 
 $$ = mm_strdup("default");
}
;


 b_expr:
 c_expr
 { 
 $$ = $1;
}
|  b_expr TYPECAST Typename
 { 
 $$ = cat_str(3,$1,mm_strdup("::"),$3);
}
|  '+' b_expr %prec UMINUS
 { 
 $$ = cat_str(2,mm_strdup("+"),$2);
}
|  '-' b_expr %prec UMINUS
 { 
 $$ = cat_str(2,mm_strdup("-"),$2);
}
|  b_expr '+' b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("+"),$3);
}
|  b_expr '-' b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("-"),$3);
}
|  b_expr '*' b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("*"),$3);
}
|  b_expr '/' b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("/"),$3);
}
|  b_expr '%' b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("%"),$3);
}
|  b_expr '^' b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("^"),$3);
}
|  b_expr '<' b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("<"),$3);
}
|  b_expr '>' b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup(">"),$3);
}
|  b_expr '=' b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("="),$3);
}
|  b_expr LESS_EQUALS b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("<="),$3);
}
|  b_expr GREATER_EQUALS b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup(">="),$3);
}
|  b_expr NOT_EQUALS b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("<>"),$3);
}
|  b_expr qual_Op b_expr %prec Op
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  qual_Op b_expr %prec Op
 { 
 $$ = cat_str(2,$1,$2);
}
|  b_expr IS DISTINCT FROM b_expr %prec IS
 { 
 $$ = cat_str(3,$1,mm_strdup("is distinct from"),$5);
}
|  b_expr IS NOT DISTINCT FROM b_expr %prec IS
 { 
 $$ = cat_str(3,$1,mm_strdup("is not distinct from"),$6);
}
|  b_expr IS DOCUMENT_P %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is document"));
}
|  b_expr IS NOT DOCUMENT_P %prec IS
 { 
 $$ = cat_str(2,$1,mm_strdup("is not document"));
}
;


 c_expr:
 columnref
 { 
 $$ = $1;
}
|  AexprConst
 { 
 $$ = $1;
}
|  ecpg_param opt_indirection
 { 
 $$ = cat_str(2,$1,$2);
}
|  '(' a_expr ')' opt_indirection
 { 
 $$ = cat_str(4,mm_strdup("("),$2,mm_strdup(")"),$4);
}
|  case_expr
 { 
 $$ = $1;
}
|  func_expr
 { 
 $$ = $1;
}
|  select_with_parens %prec UMINUS
 { 
 $$ = $1;
}
|  select_with_parens indirection
 { 
 $$ = cat_str(2,$1,$2);
}
|  EXISTS select_with_parens
 { 
 $$ = cat_str(2,mm_strdup("exists"),$2);
}
|  ARRAY select_with_parens
 { 
 $$ = cat_str(2,mm_strdup("array"),$2);
}
|  ARRAY array_expr
 { 
 $$ = cat_str(2,mm_strdup("array"),$2);
}
|  explicit_row
 { 
 $$ = $1;
}
|  implicit_row
 { 
 $$ = $1;
}
|  GROUPING '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("grouping ("),$3,mm_strdup(")"));
}
;


 func_application:
 func_name '(' ')'
 { 
 $$ = cat_str(2,$1,mm_strdup("( )"));
}
|  func_name '(' func_arg_list opt_sort_clause ')'
 { 
 $$ = cat_str(5,$1,mm_strdup("("),$3,$4,mm_strdup(")"));
}
|  func_name '(' VARIADIC func_arg_expr opt_sort_clause ')'
 { 
 $$ = cat_str(5,$1,mm_strdup("( variadic"),$4,$5,mm_strdup(")"));
}
|  func_name '(' func_arg_list ',' VARIADIC func_arg_expr opt_sort_clause ')'
 { 
 $$ = cat_str(7,$1,mm_strdup("("),$3,mm_strdup(", variadic"),$6,$7,mm_strdup(")"));
}
|  func_name '(' ALL func_arg_list opt_sort_clause ')'
 { 
 $$ = cat_str(5,$1,mm_strdup("( all"),$4,$5,mm_strdup(")"));
}
|  func_name '(' DISTINCT func_arg_list opt_sort_clause ')'
 { 
 $$ = cat_str(5,$1,mm_strdup("( distinct"),$4,$5,mm_strdup(")"));
}
|  func_name '(' '*' ')'
 { 
 $$ = cat_str(2,$1,mm_strdup("( * )"));
}
;


 func_expr:
 func_application within_group_clause filter_clause over_clause
 { 
 $$ = cat_str(4,$1,$2,$3,$4);
}
|  func_expr_common_subexpr
 { 
 $$ = $1;
}
;


 func_expr_windowless:
 func_application
 { 
 $$ = $1;
}
|  func_expr_common_subexpr
 { 
 $$ = $1;
}
;


 func_expr_common_subexpr:
 COLLATION FOR '(' a_expr ')'
 { 
 $$ = cat_str(3,mm_strdup("collation for ("),$4,mm_strdup(")"));
}
|  CURRENT_DATE
 { 
 $$ = mm_strdup("current_date");
}
|  CURRENT_TIME
 { 
 $$ = mm_strdup("current_time");
}
|  CURRENT_TIME '(' Iconst ')'
 { 
 $$ = cat_str(3,mm_strdup("current_time ("),$3,mm_strdup(")"));
}
|  CURRENT_TIMESTAMP
 { 
 $$ = mm_strdup("current_timestamp");
}
|  CURRENT_TIMESTAMP '(' Iconst ')'
 { 
 $$ = cat_str(3,mm_strdup("current_timestamp ("),$3,mm_strdup(")"));
}
|  LOCALTIME
 { 
 $$ = mm_strdup("localtime");
}
|  LOCALTIME '(' Iconst ')'
 { 
 $$ = cat_str(3,mm_strdup("localtime ("),$3,mm_strdup(")"));
}
|  LOCALTIMESTAMP
 { 
 $$ = mm_strdup("localtimestamp");
}
|  LOCALTIMESTAMP '(' Iconst ')'
 { 
 $$ = cat_str(3,mm_strdup("localtimestamp ("),$3,mm_strdup(")"));
}
|  CURRENT_ROLE
 { 
 $$ = mm_strdup("current_role");
}
|  CURRENT_USER
 { 
 $$ = mm_strdup("current_user");
}
|  SESSION_USER
 { 
 $$ = mm_strdup("session_user");
}
|  USER
 { 
 $$ = mm_strdup("user");
}
|  CURRENT_CATALOG
 { 
 $$ = mm_strdup("current_catalog");
}
|  CURRENT_SCHEMA
 { 
 $$ = mm_strdup("current_schema");
}
|  CAST '(' a_expr AS Typename ')'
 { 
 $$ = cat_str(5,mm_strdup("cast ("),$3,mm_strdup("as"),$5,mm_strdup(")"));
}
|  EXTRACT '(' extract_list ')'
 { 
 $$ = cat_str(3,mm_strdup("extract ("),$3,mm_strdup(")"));
}
|  NORMALIZE '(' a_expr ')'
 { 
 $$ = cat_str(3,mm_strdup("normalize ("),$3,mm_strdup(")"));
}
|  NORMALIZE '(' a_expr ',' unicode_normal_form ')'
 { 
 $$ = cat_str(5,mm_strdup("normalize ("),$3,mm_strdup(","),$5,mm_strdup(")"));
}
|  OVERLAY '(' overlay_list ')'
 { 
 $$ = cat_str(3,mm_strdup("overlay ("),$3,mm_strdup(")"));
}
|  OVERLAY '(' func_arg_list_opt ')'
 { 
 $$ = cat_str(3,mm_strdup("overlay ("),$3,mm_strdup(")"));
}
|  POSITION '(' position_list ')'
 { 
 $$ = cat_str(3,mm_strdup("position ("),$3,mm_strdup(")"));
}
|  SUBSTRING '(' substr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("substring ("),$3,mm_strdup(")"));
}
|  SUBSTRING '(' func_arg_list_opt ')'
 { 
 $$ = cat_str(3,mm_strdup("substring ("),$3,mm_strdup(")"));
}
|  TREAT '(' a_expr AS Typename ')'
 { 
 $$ = cat_str(5,mm_strdup("treat ("),$3,mm_strdup("as"),$5,mm_strdup(")"));
}
|  TRIM '(' BOTH trim_list ')'
 { 
 $$ = cat_str(3,mm_strdup("trim ( both"),$4,mm_strdup(")"));
}
|  TRIM '(' LEADING trim_list ')'
 { 
 $$ = cat_str(3,mm_strdup("trim ( leading"),$4,mm_strdup(")"));
}
|  TRIM '(' TRAILING trim_list ')'
 { 
 $$ = cat_str(3,mm_strdup("trim ( trailing"),$4,mm_strdup(")"));
}
|  TRIM '(' trim_list ')'
 { 
 $$ = cat_str(3,mm_strdup("trim ("),$3,mm_strdup(")"));
}
|  NULLIF '(' a_expr ',' a_expr ')'
 { 
 $$ = cat_str(5,mm_strdup("nullif ("),$3,mm_strdup(","),$5,mm_strdup(")"));
}
|  COALESCE '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("coalesce ("),$3,mm_strdup(")"));
}
|  GREATEST '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("greatest ("),$3,mm_strdup(")"));
}
|  LEAST '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("least ("),$3,mm_strdup(")"));
}
|  XMLCONCAT '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("xmlconcat ("),$3,mm_strdup(")"));
}
|  XMLELEMENT '(' NAME_P ColLabel ')'
 { 
 $$ = cat_str(3,mm_strdup("xmlelement ( name"),$4,mm_strdup(")"));
}
|  XMLELEMENT '(' NAME_P ColLabel ',' xml_attributes ')'
 { 
 $$ = cat_str(5,mm_strdup("xmlelement ( name"),$4,mm_strdup(","),$6,mm_strdup(")"));
}
|  XMLELEMENT '(' NAME_P ColLabel ',' expr_list ')'
 { 
 $$ = cat_str(5,mm_strdup("xmlelement ( name"),$4,mm_strdup(","),$6,mm_strdup(")"));
}
|  XMLELEMENT '(' NAME_P ColLabel ',' xml_attributes ',' expr_list ')'
 { 
 $$ = cat_str(7,mm_strdup("xmlelement ( name"),$4,mm_strdup(","),$6,mm_strdup(","),$8,mm_strdup(")"));
}
|  XMLEXISTS '(' c_expr xmlexists_argument ')'
 { 
 $$ = cat_str(4,mm_strdup("xmlexists ("),$3,$4,mm_strdup(")"));
}
|  XMLFOREST '(' xml_attribute_list ')'
 { 
 $$ = cat_str(3,mm_strdup("xmlforest ("),$3,mm_strdup(")"));
}
|  XMLPARSE '(' document_or_content a_expr xml_whitespace_option ')'
 { 
 $$ = cat_str(5,mm_strdup("xmlparse ("),$3,$4,$5,mm_strdup(")"));
}
|  XMLPI '(' NAME_P ColLabel ')'
 { 
 $$ = cat_str(3,mm_strdup("xmlpi ( name"),$4,mm_strdup(")"));
}
|  XMLPI '(' NAME_P ColLabel ',' a_expr ')'
 { 
 $$ = cat_str(5,mm_strdup("xmlpi ( name"),$4,mm_strdup(","),$6,mm_strdup(")"));
}
|  XMLROOT '(' a_expr ',' xml_root_version opt_xml_root_standalone ')'
 { 
 $$ = cat_str(6,mm_strdup("xmlroot ("),$3,mm_strdup(","),$5,$6,mm_strdup(")"));
}
|  XMLSERIALIZE '(' document_or_content a_expr AS SimpleTypename ')'
 { 
 $$ = cat_str(6,mm_strdup("xmlserialize ("),$3,$4,mm_strdup("as"),$6,mm_strdup(")"));
}
;


 xml_root_version:
 VERSION_P a_expr
 { 
 $$ = cat_str(2,mm_strdup("version"),$2);
}
|  VERSION_P NO VALUE_P
 { 
 $$ = mm_strdup("version no value");
}
;


 opt_xml_root_standalone:
 ',' STANDALONE_P YES_P
 { 
 $$ = mm_strdup(", standalone yes");
}
|  ',' STANDALONE_P NO
 { 
 $$ = mm_strdup(", standalone no");
}
|  ',' STANDALONE_P NO VALUE_P
 { 
 $$ = mm_strdup(", standalone no value");
}
| 
 { 
 $$=EMPTY; }
;


 xml_attributes:
 XMLATTRIBUTES '(' xml_attribute_list ')'
 { 
 $$ = cat_str(3,mm_strdup("xmlattributes ("),$3,mm_strdup(")"));
}
;


 xml_attribute_list:
 xml_attribute_el
 { 
 $$ = $1;
}
|  xml_attribute_list ',' xml_attribute_el
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 xml_attribute_el:
 a_expr AS ColLabel
 { 
 $$ = cat_str(3,$1,mm_strdup("as"),$3);
}
|  a_expr
 { 
 $$ = $1;
}
;


 document_or_content:
 DOCUMENT_P
 { 
 $$ = mm_strdup("document");
}
|  CONTENT_P
 { 
 $$ = mm_strdup("content");
}
;


 xml_whitespace_option:
 PRESERVE WHITESPACE_P
 { 
 $$ = mm_strdup("preserve whitespace");
}
|  STRIP_P WHITESPACE_P
 { 
 $$ = mm_strdup("strip whitespace");
}
| 
 { 
 $$=EMPTY; }
;


 xmlexists_argument:
 PASSING c_expr
 { 
 $$ = cat_str(2,mm_strdup("passing"),$2);
}
|  PASSING c_expr xml_passing_mech
 { 
 $$ = cat_str(3,mm_strdup("passing"),$2,$3);
}
|  PASSING xml_passing_mech c_expr
 { 
 $$ = cat_str(3,mm_strdup("passing"),$2,$3);
}
|  PASSING xml_passing_mech c_expr xml_passing_mech
 { 
 $$ = cat_str(4,mm_strdup("passing"),$2,$3,$4);
}
;


 xml_passing_mech:
 BY REF_P
 { 
 $$ = mm_strdup("by ref");
}
|  BY VALUE_P
 { 
 $$ = mm_strdup("by value");
}
;


 within_group_clause:
 WITHIN GROUP_P '(' sort_clause ')'
 { 
 $$ = cat_str(3,mm_strdup("within group ("),$4,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 filter_clause:
 FILTER '(' WHERE a_expr ')'
 { 
 $$ = cat_str(3,mm_strdup("filter ( where"),$4,mm_strdup(")"));
}
| 
 { 
 $$=EMPTY; }
;


 window_clause:
 WINDOW window_definition_list
 { 
 $$ = cat_str(2,mm_strdup("window"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 window_definition_list:
 window_definition
 { 
 $$ = $1;
}
|  window_definition_list ',' window_definition
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 window_definition:
 ColId AS window_specification
 { 
 $$ = cat_str(3,$1,mm_strdup("as"),$3);
}
;


 over_clause:
 OVER window_specification
 { 
 $$ = cat_str(2,mm_strdup("over"),$2);
}
|  OVER ColId
 { 
 $$ = cat_str(2,mm_strdup("over"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 window_specification:
 '(' opt_existing_window_name opt_partition_clause opt_sort_clause opt_frame_clause ')'
 { 
 $$ = cat_str(6,mm_strdup("("),$2,$3,$4,$5,mm_strdup(")"));
}
;


 opt_existing_window_name:
 ColId
 { 
 $$ = $1;
}
|  %prec Op
 { 
 $$=EMPTY; }
;


 opt_partition_clause:
 PARTITION BY expr_list
 { 
 $$ = cat_str(2,mm_strdup("partition by"),$3);
}
| 
 { 
 $$=EMPTY; }
;


 opt_frame_clause:
 RANGE frame_extent opt_window_exclusion_clause
 { 
 $$ = cat_str(3,mm_strdup("range"),$2,$3);
}
|  ROWS frame_extent opt_window_exclusion_clause
 { 
 $$ = cat_str(3,mm_strdup("rows"),$2,$3);
}
|  GROUPS frame_extent opt_window_exclusion_clause
 { 
 $$ = cat_str(3,mm_strdup("groups"),$2,$3);
}
| 
 { 
 $$=EMPTY; }
;


 frame_extent:
 frame_bound
 { 
 $$ = $1;
}
|  BETWEEN frame_bound AND frame_bound
 { 
 $$ = cat_str(4,mm_strdup("between"),$2,mm_strdup("and"),$4);
}
;


 frame_bound:
 UNBOUNDED PRECEDING
 { 
 $$ = mm_strdup("unbounded preceding");
}
|  UNBOUNDED FOLLOWING
 { 
 $$ = mm_strdup("unbounded following");
}
|  CURRENT_P ROW
 { 
 $$ = mm_strdup("current row");
}
|  a_expr PRECEDING
 { 
 $$ = cat_str(2,$1,mm_strdup("preceding"));
}
|  a_expr FOLLOWING
 { 
 $$ = cat_str(2,$1,mm_strdup("following"));
}
;


 opt_window_exclusion_clause:
 EXCLUDE CURRENT_P ROW
 { 
 $$ = mm_strdup("exclude current row");
}
|  EXCLUDE GROUP_P
 { 
 $$ = mm_strdup("exclude group");
}
|  EXCLUDE TIES
 { 
 $$ = mm_strdup("exclude ties");
}
|  EXCLUDE NO OTHERS
 { 
 $$ = mm_strdup("exclude no others");
}
| 
 { 
 $$=EMPTY; }
;


 row:
 ROW '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("row ("),$3,mm_strdup(")"));
}
|  ROW '(' ')'
 { 
 $$ = mm_strdup("row ( )");
}
|  '(' expr_list ',' a_expr ')'
 { 
 $$ = cat_str(5,mm_strdup("("),$2,mm_strdup(","),$4,mm_strdup(")"));
}
;


 explicit_row:
 ROW '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("row ("),$3,mm_strdup(")"));
}
|  ROW '(' ')'
 { 
 $$ = mm_strdup("row ( )");
}
;


 implicit_row:
 '(' expr_list ',' a_expr ')'
 { 
 $$ = cat_str(5,mm_strdup("("),$2,mm_strdup(","),$4,mm_strdup(")"));
}
;


 sub_type:
 ANY
 { 
 $$ = mm_strdup("any");
}
|  SOME
 { 
 $$ = mm_strdup("some");
}
|  ALL
 { 
 $$ = mm_strdup("all");
}
;


 all_Op:
 Op
 { 
 $$ = $1;
}
|  MathOp
 { 
 $$ = $1;
}
;


 MathOp:
 '+'
 { 
 $$ = mm_strdup("+");
}
|  '-'
 { 
 $$ = mm_strdup("-");
}
|  '*'
 { 
 $$ = mm_strdup("*");
}
|  '/'
 { 
 $$ = mm_strdup("/");
}
|  '%'
 { 
 $$ = mm_strdup("%");
}
|  '^'
 { 
 $$ = mm_strdup("^");
}
|  '<'
 { 
 $$ = mm_strdup("<");
}
|  '>'
 { 
 $$ = mm_strdup(">");
}
|  '='
 { 
 $$ = mm_strdup("=");
}
|  LESS_EQUALS
 { 
 $$ = mm_strdup("<=");
}
|  GREATER_EQUALS
 { 
 $$ = mm_strdup(">=");
}
|  NOT_EQUALS
 { 
 $$ = mm_strdup("<>");
}
;


 qual_Op:
 Op
 { 
 $$ = $1;
}
|  OPERATOR '(' any_operator ')'
 { 
 $$ = cat_str(3,mm_strdup("operator ("),$3,mm_strdup(")"));
}
;


 qual_all_Op:
 all_Op
 { 
 $$ = $1;
}
|  OPERATOR '(' any_operator ')'
 { 
 $$ = cat_str(3,mm_strdup("operator ("),$3,mm_strdup(")"));
}
;


 subquery_Op:
 all_Op
 { 
 $$ = $1;
}
|  OPERATOR '(' any_operator ')'
 { 
 $$ = cat_str(3,mm_strdup("operator ("),$3,mm_strdup(")"));
}
|  LIKE
 { 
 $$ = mm_strdup("like");
}
|  NOT_LA LIKE
 { 
 $$ = mm_strdup("not like");
}
|  ILIKE
 { 
 $$ = mm_strdup("ilike");
}
|  NOT_LA ILIKE
 { 
 $$ = mm_strdup("not ilike");
}
;


 expr_list:
 a_expr
 { 
 $$ = $1;
}
|  expr_list ',' a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 func_arg_list:
 func_arg_expr
 { 
 $$ = $1;
}
|  func_arg_list ',' func_arg_expr
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 func_arg_expr:
 a_expr
 { 
 $$ = $1;
}
|  param_name COLON_EQUALS a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup(":="),$3);
}
|  param_name EQUALS_GREATER a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("=>"),$3);
}
;


 func_arg_list_opt:
 func_arg_list
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 type_list:
 Typename
 { 
 $$ = $1;
}
|  type_list ',' Typename
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 array_expr:
 '[' expr_list ']'
 { 
 $$ = cat_str(3,mm_strdup("["),$2,mm_strdup("]"));
}
|  '[' array_expr_list ']'
 { 
 $$ = cat_str(3,mm_strdup("["),$2,mm_strdup("]"));
}
|  '[' ']'
 { 
 $$ = mm_strdup("[ ]");
}
;


 array_expr_list:
 array_expr
 { 
 $$ = $1;
}
|  array_expr_list ',' array_expr
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 extract_list:
 extract_arg FROM a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("from"),$3);
}
;


 extract_arg:
 ecpg_ident
 { 
 $$ = $1;
}
|  YEAR_P
 { 
 $$ = mm_strdup("year");
}
|  MONTH_P
 { 
 $$ = mm_strdup("month");
}
|  DAY_P
 { 
 $$ = mm_strdup("day");
}
|  HOUR_P
 { 
 $$ = mm_strdup("hour");
}
|  MINUTE_P
 { 
 $$ = mm_strdup("minute");
}
|  SECOND_P
 { 
 $$ = mm_strdup("second");
}
|  ecpg_sconst
 { 
 $$ = $1;
}
;


 unicode_normal_form:
 NFC
 { 
 $$ = mm_strdup("nfc");
}
|  NFD
 { 
 $$ = mm_strdup("nfd");
}
|  NFKC
 { 
 $$ = mm_strdup("nfkc");
}
|  NFKD
 { 
 $$ = mm_strdup("nfkd");
}
;


 overlay_list:
 a_expr PLACING a_expr FROM a_expr FOR a_expr
 { 
 $$ = cat_str(7,$1,mm_strdup("placing"),$3,mm_strdup("from"),$5,mm_strdup("for"),$7);
}
|  a_expr PLACING a_expr FROM a_expr
 { 
 $$ = cat_str(5,$1,mm_strdup("placing"),$3,mm_strdup("from"),$5);
}
;


 position_list:
 b_expr IN_P b_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("in"),$3);
}
;


 substr_list:
 a_expr FROM a_expr FOR a_expr
 { 
 $$ = cat_str(5,$1,mm_strdup("from"),$3,mm_strdup("for"),$5);
}
|  a_expr FOR a_expr FROM a_expr
 { 
 $$ = cat_str(5,$1,mm_strdup("for"),$3,mm_strdup("from"),$5);
}
|  a_expr FROM a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("from"),$3);
}
|  a_expr FOR a_expr
 { 
 $$ = cat_str(3,$1,mm_strdup("for"),$3);
}
|  a_expr SIMILAR a_expr ESCAPE a_expr
 { 
 $$ = cat_str(5,$1,mm_strdup("similar"),$3,mm_strdup("escape"),$5);
}
;


 trim_list:
 a_expr FROM expr_list
 { 
 $$ = cat_str(3,$1,mm_strdup("from"),$3);
}
|  FROM expr_list
 { 
 $$ = cat_str(2,mm_strdup("from"),$2);
}
|  expr_list
 { 
 $$ = $1;
}
;


 in_expr:
 select_with_parens
 { 
 $$ = $1;
}
|  '(' expr_list ')'
 { 
 $$ = cat_str(3,mm_strdup("("),$2,mm_strdup(")"));
}
;


 case_expr:
 CASE case_arg when_clause_list case_default END_P
 { 
 $$ = cat_str(5,mm_strdup("case"),$2,$3,$4,mm_strdup("end"));
}
;


 when_clause_list:
 when_clause
 { 
 $$ = $1;
}
|  when_clause_list when_clause
 { 
 $$ = cat_str(2,$1,$2);
}
;


 when_clause:
 WHEN a_expr THEN a_expr
 { 
 $$ = cat_str(4,mm_strdup("when"),$2,mm_strdup("then"),$4);
}
;


 case_default:
 ELSE a_expr
 { 
 $$ = cat_str(2,mm_strdup("else"),$2);
}
| 
 { 
 $$=EMPTY; }
;


 case_arg:
 a_expr
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 columnref:
 ColId
 { 
 $$ = $1;
}
|  ColId indirection
 { 
 $$ = cat_str(2,$1,$2);
}
;


 indirection_el:
 '.' attr_name
 { 
 $$ = cat_str(2,mm_strdup("."),$2);
}
|  '.' '*'
 { 
 $$ = mm_strdup(". *");
}
|  '[' a_expr ']'
 { 
 $$ = cat_str(3,mm_strdup("["),$2,mm_strdup("]"));
}
|  '[' opt_slice_bound ':' opt_slice_bound ']'
 { 
 $$ = cat_str(5,mm_strdup("["),$2,mm_strdup(":"),$4,mm_strdup("]"));
}
;


 opt_slice_bound:
 a_expr
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 indirection:
 indirection_el
 { 
 $$ = $1;
}
|  indirection indirection_el
 { 
 $$ = cat_str(2,$1,$2);
}
;


 opt_indirection:

 { 
 $$=EMPTY; }
|  opt_indirection indirection_el
 { 
 $$ = cat_str(2,$1,$2);
}
;


 opt_asymmetric:
 ASYMMETRIC
 { 
 $$ = mm_strdup("asymmetric");
}
| 
 { 
 $$=EMPTY; }
;


 opt_target_list:
 target_list
 { 
 $$ = $1;
}
| 
 { 
 $$=EMPTY; }
;


 target_list:
 target_el
 { 
 $$ = $1;
}
|  target_list ',' target_el
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 target_el:
 a_expr AS ColLabel
 { 
 $$ = cat_str(3,$1,mm_strdup("as"),$3);
}
|  a_expr BareColLabel
 { 
 $$ = cat_str(2,$1,$2);
}
|  a_expr
 { 
 $$ = $1;
}
|  '*'
 { 
 $$ = mm_strdup("*");
}
;


 qualified_name_list:
 qualified_name
 { 
 $$ = $1;
}
|  qualified_name_list ',' qualified_name
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 qualified_name:
 ColId
 { 
 $$ = $1;
}
|  ColId indirection
 { 
 $$ = cat_str(2,$1,$2);
}
;


 name_list:
 name
 { 
 $$ = $1;
}
|  name_list ',' name
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 name:
 ColId
 { 
 $$ = $1;
}
;


 attr_name:
 ColLabel
 { 
 $$ = $1;
}
;


 file_name:
 ecpg_sconst
 { 
 $$ = $1;
}
;


 func_name:
 type_function_name
 { 
 $$ = $1;
}
|  ColId indirection
 { 
 $$ = cat_str(2,$1,$2);
}
;


 AexprConst:
 Iconst
 { 
 $$ = $1;
}
|  ecpg_fconst
 { 
 $$ = $1;
}
|  ecpg_sconst
 { 
 $$ = $1;
}
|  ecpg_bconst
 { 
 $$ = $1;
}
|  ecpg_xconst
 { 
 $$ = $1;
}
|  func_name ecpg_sconst
 { 
 $$ = cat_str(2,$1,$2);
}
|  func_name '(' func_arg_list opt_sort_clause ')' ecpg_sconst
 { 
 $$ = cat_str(6,$1,mm_strdup("("),$3,$4,mm_strdup(")"),$6);
}
|  ConstTypename ecpg_sconst
 { 
 $$ = cat_str(2,$1,$2);
}
|  ConstInterval ecpg_sconst opt_interval
 { 
 $$ = cat_str(3,$1,$2,$3);
}
|  ConstInterval '(' Iconst ')' ecpg_sconst
 { 
 $$ = cat_str(5,$1,mm_strdup("("),$3,mm_strdup(")"),$5);
}
|  TRUE_P
 { 
 $$ = mm_strdup("true");
}
|  FALSE_P
 { 
 $$ = mm_strdup("false");
}
|  NULL_P
 { 
 $$ = mm_strdup("null");
}
	| civar			{ $$ = $1; }
	| civarind		{ $$ = $1; }
;


 Iconst:
 ICONST
	{ $$ = make_name(); }
;


 SignedIconst:
 Iconst
 { 
 $$ = $1;
}
	| civar	{ $$ = $1; }
|  '+' Iconst
 { 
 $$ = cat_str(2,mm_strdup("+"),$2);
}
|  '-' Iconst
 { 
 $$ = cat_str(2,mm_strdup("-"),$2);
}
;


 RoleId:
 RoleSpec
 { 
 $$ = $1;
}
;


 RoleSpec:
 NonReservedWord
 { 
 $$ = $1;
}
|  CURRENT_ROLE
 { 
 $$ = mm_strdup("current_role");
}
|  CURRENT_USER
 { 
 $$ = mm_strdup("current_user");
}
|  SESSION_USER
 { 
 $$ = mm_strdup("session_user");
}
;


 role_list:
 RoleSpec
 { 
 $$ = $1;
}
|  role_list ',' RoleSpec
 { 
 $$ = cat_str(3,$1,mm_strdup(","),$3);
}
;


 NonReservedWord:
 ecpg_ident
 { 
 $$ = $1;
}
|  unreserved_keyword
 { 
 $$ = $1;
}
|  col_name_keyword
 { 
 $$ = $1;
}
|  type_func_name_keyword
 { 
 $$ = $1;
}
;


 BareColLabel:
 ecpg_ident
 { 
 $$ = $1;
}
|  bare_label_keyword
 { 
 $$ = $1;
}
;


 unreserved_keyword:
 ABORT_P
 { 
 $$ = mm_strdup("abort");
}
|  ABSOLUTE_P
 { 
 $$ = mm_strdup("absolute");
}
|  ACCESS
 { 
 $$ = mm_strdup("access");
}
|  ACTION
 { 
 $$ = mm_strdup("action");
}
|  ADD_P
 { 
 $$ = mm_strdup("add");
}
|  ADMIN
 { 
 $$ = mm_strdup("admin");
}
|  AFTER
 { 
 $$ = mm_strdup("after");
}
|  AGGREGATE
 { 
 $$ = mm_strdup("aggregate");
}
|  ALSO
 { 
 $$ = mm_strdup("also");
}
|  ALTER
 { 
 $$ = mm_strdup("alter");
}
|  ALWAYS
 { 
 $$ = mm_strdup("always");
}
|  ASENSITIVE
 { 
 $$ = mm_strdup("asensitive");
}
|  ASSERTION
 { 
 $$ = mm_strdup("assertion");
}
|  ASSIGNMENT
 { 
 $$ = mm_strdup("assignment");
}
|  AT
 { 
 $$ = mm_strdup("at");
}
|  ATOMIC
 { 
 $$ = mm_strdup("atomic");
}
|  ATTACH
 { 
 $$ = mm_strdup("attach");
}
|  ATTRIBUTE
 { 
 $$ = mm_strdup("attribute");
}
|  BACKWARD
 { 
 $$ = mm_strdup("backward");
}
|  BEFORE
 { 
 $$ = mm_strdup("before");
}
|  BEGIN_P
 { 
 $$ = mm_strdup("begin");
}
|  BREADTH
 { 
 $$ = mm_strdup("breadth");
}
|  BY
 { 
 $$ = mm_strdup("by");
}
|  CACHE
 { 
 $$ = mm_strdup("cache");
}
|  CALL
 { 
 $$ = mm_strdup("call");
}
|  CALLED
 { 
 $$ = mm_strdup("called");
}
|  CASCADE
 { 
 $$ = mm_strdup("cascade");
}
|  CASCADED
 { 
 $$ = mm_strdup("cascaded");
}
|  CATALOG_P
 { 
 $$ = mm_strdup("catalog");
}
|  CHAIN
 { 
 $$ = mm_strdup("chain");
}
|  CHARACTERISTICS
 { 
 $$ = mm_strdup("characteristics");
}
|  CHECKPOINT
 { 
 $$ = mm_strdup("checkpoint");
}
|  CLASS
 { 
 $$ = mm_strdup("class");
}
|  CLOSE
 { 
 $$ = mm_strdup("close");
}
|  CLUSTER
 { 
 $$ = mm_strdup("cluster");
}
|  COLUMNS
 { 
 $$ = mm_strdup("columns");
}
|  COMMENT
 { 
 $$ = mm_strdup("comment");
}
|  COMMENTS
 { 
 $$ = mm_strdup("comments");
}
|  COMMIT
 { 
 $$ = mm_strdup("commit");
}
|  COMMITTED
 { 
 $$ = mm_strdup("committed");
}
|  COMPRESSION
 { 
 $$ = mm_strdup("compression");
}
|  CONFIGURATION
 { 
 $$ = mm_strdup("configuration");
}
|  CONFLICT
 { 
 $$ = mm_strdup("conflict");
}
|  CONSTRAINTS
 { 
 $$ = mm_strdup("constraints");
}
|  CONTENT_P
 { 
 $$ = mm_strdup("content");
}
|  CONTINUE_P
 { 
 $$ = mm_strdup("continue");
}
|  CONVERSION_P
 { 
 $$ = mm_strdup("conversion");
}
|  COPY
 { 
 $$ = mm_strdup("copy");
}
|  COST
 { 
 $$ = mm_strdup("cost");
}
|  CSV
 { 
 $$ = mm_strdup("csv");
}
|  CUBE
 { 
 $$ = mm_strdup("cube");
}
|  CURSOR
 { 
 $$ = mm_strdup("cursor");
}
|  CYCLE
 { 
 $$ = mm_strdup("cycle");
}
|  DATA_P
 { 
 $$ = mm_strdup("data");
}
|  DATABASE
 { 
 $$ = mm_strdup("database");
}
|  DEALLOCATE
 { 
 $$ = mm_strdup("deallocate");
}
|  DECLARE
 { 
 $$ = mm_strdup("declare");
}
|  DEFAULTS
 { 
 $$ = mm_strdup("defaults");
}
|  DEFERRED
 { 
 $$ = mm_strdup("deferred");
}
|  DEFINER
 { 
 $$ = mm_strdup("definer");
}
|  DELETE_P
 { 
 $$ = mm_strdup("delete");
}
|  DELIMITER
 { 
 $$ = mm_strdup("delimiter");
}
|  DELIMITERS
 { 
 $$ = mm_strdup("delimiters");
}
|  DEPENDS
 { 
 $$ = mm_strdup("depends");
}
|  DEPTH
 { 
 $$ = mm_strdup("depth");
}
|  DETACH
 { 
 $$ = mm_strdup("detach");
}
|  DICTIONARY
 { 
 $$ = mm_strdup("dictionary");
}
|  DISABLE_P
 { 
 $$ = mm_strdup("disable");
}
|  DISCARD
 { 
 $$ = mm_strdup("discard");
}
|  DOCUMENT_P
 { 
 $$ = mm_strdup("document");
}
|  DOMAIN_P
 { 
 $$ = mm_strdup("domain");
}
|  DOUBLE_P
 { 
 $$ = mm_strdup("double");
}
|  DROP
 { 
 $$ = mm_strdup("drop");
}
|  EACH
 { 
 $$ = mm_strdup("each");
}
|  ENABLE_P
 { 
 $$ = mm_strdup("enable");
}
|  ENCODING
 { 
 $$ = mm_strdup("encoding");
}
|  ENCRYPTED
 { 
 $$ = mm_strdup("encrypted");
}
|  ENUM_P
 { 
 $$ = mm_strdup("enum");
}
|  ESCAPE
 { 
 $$ = mm_strdup("escape");
}
|  EVENT
 { 
 $$ = mm_strdup("event");
}
|  EXCLUDE
 { 
 $$ = mm_strdup("exclude");
}
|  EXCLUDING
 { 
 $$ = mm_strdup("excluding");
}
|  EXCLUSIVE
 { 
 $$ = mm_strdup("exclusive");
}
|  EXECUTE
 { 
 $$ = mm_strdup("execute");
}
|  EXPLAIN
 { 
 $$ = mm_strdup("explain");
}
|  EXPRESSION
 { 
 $$ = mm_strdup("expression");
}
|  EXTENSION
 { 
 $$ = mm_strdup("extension");
}
|  EXTERNAL
 { 
 $$ = mm_strdup("external");
}
|  FAMILY
 { 
 $$ = mm_strdup("family");
}
|  FILTER
 { 
 $$ = mm_strdup("filter");
}
|  FINALIZE
 { 
 $$ = mm_strdup("finalize");
}
|  FIRST_P
 { 
 $$ = mm_strdup("first");
}
|  FOLLOWING
 { 
 $$ = mm_strdup("following");
}
|  FORCE
 { 
 $$ = mm_strdup("force");
}
|  FORWARD
 { 
 $$ = mm_strdup("forward");
}
|  FUNCTION
 { 
 $$ = mm_strdup("function");
}
|  FUNCTIONS
 { 
 $$ = mm_strdup("functions");
}
|  GENERATED
 { 
 $$ = mm_strdup("generated");
}
|  GLOBAL
 { 
 $$ = mm_strdup("global");
}
|  GRANTED
 { 
 $$ = mm_strdup("granted");
}
|  GROUPS
 { 
 $$ = mm_strdup("groups");
}
|  HANDLER
 { 
 $$ = mm_strdup("handler");
}
|  HEADER_P
 { 
 $$ = mm_strdup("header");
}
|  HOLD
 { 
 $$ = mm_strdup("hold");
}
|  IDENTITY_P
 { 
 $$ = mm_strdup("identity");
}
|  IF_P
 { 
 $$ = mm_strdup("if");
}
|  IMMEDIATE
 { 
 $$ = mm_strdup("immediate");
}
|  IMMUTABLE
 { 
 $$ = mm_strdup("immutable");
}
|  IMPLICIT_P
 { 
 $$ = mm_strdup("implicit");
}
|  IMPORT_P
 { 
 $$ = mm_strdup("import");
}
|  INCLUDE
 { 
 $$ = mm_strdup("include");
}
|  INCLUDING
 { 
 $$ = mm_strdup("including");
}
|  INCREMENT
 { 
 $$ = mm_strdup("increment");
}
|  INDEX
 { 
 $$ = mm_strdup("index");
}
|  INDEXES
 { 
 $$ = mm_strdup("indexes");
}
|  INHERIT
 { 
 $$ = mm_strdup("inherit");
}
|  INHERITS
 { 
 $$ = mm_strdup("inherits");
}
|  INLINE_P
 { 
 $$ = mm_strdup("inline");
}
|  INSENSITIVE
 { 
 $$ = mm_strdup("insensitive");
}
|  INSERT
 { 
 $$ = mm_strdup("insert");
}
|  INSTEAD
 { 
 $$ = mm_strdup("instead");
}
|  INVOKER
 { 
 $$ = mm_strdup("invoker");
}
|  ISOLATION
 { 
 $$ = mm_strdup("isolation");
}
|  KEY
 { 
 $$ = mm_strdup("key");
}
|  LABEL
 { 
 $$ = mm_strdup("label");
}
|  LANGUAGE
 { 
 $$ = mm_strdup("language");
}
|  LARGE_P
 { 
 $$ = mm_strdup("large");
}
|  LAST_P
 { 
 $$ = mm_strdup("last");
}
|  LEAKPROOF
 { 
 $$ = mm_strdup("leakproof");
}
|  LEVEL
 { 
 $$ = mm_strdup("level");
}
|  LISTEN
 { 
 $$ = mm_strdup("listen");
}
|  LOAD
 { 
 $$ = mm_strdup("load");
}
|  LOCAL
 { 
 $$ = mm_strdup("local");
}
|  LOCATION
 { 
 $$ = mm_strdup("location");
}
|  LOCK_P
 { 
 $$ = mm_strdup("lock");
}
|  LOCKED
 { 
 $$ = mm_strdup("locked");
}
|  LOGGED
 { 
 $$ = mm_strdup("logged");
}
|  MAPPING
 { 
 $$ = mm_strdup("mapping");
}
|  MATCH
 { 
 $$ = mm_strdup("match");
}
|  MATERIALIZED
 { 
 $$ = mm_strdup("materialized");
}
|  MAXVALUE
 { 
 $$ = mm_strdup("maxvalue");
}
|  METHOD
 { 
 $$ = mm_strdup("method");
}
|  MINVALUE
 { 
 $$ = mm_strdup("minvalue");
}
|  MODE
 { 
 $$ = mm_strdup("mode");
}
|  MOVE
 { 
 $$ = mm_strdup("move");
}
|  NAME_P
 { 
 $$ = mm_strdup("name");
}
|  NAMES
 { 
 $$ = mm_strdup("names");
}
|  NEW
 { 
 $$ = mm_strdup("new");
}
|  NEXT
 { 
 $$ = mm_strdup("next");
}
|  NFC
 { 
 $$ = mm_strdup("nfc");
}
|  NFD
 { 
 $$ = mm_strdup("nfd");
}
|  NFKC
 { 
 $$ = mm_strdup("nfkc");
}
|  NFKD
 { 
 $$ = mm_strdup("nfkd");
}
|  NO
 { 
 $$ = mm_strdup("no");
}
|  NORMALIZED
 { 
 $$ = mm_strdup("normalized");
}
|  NOTHING
 { 
 $$ = mm_strdup("nothing");
}
|  NOTIFY
 { 
 $$ = mm_strdup("notify");
}
|  NOWAIT
 { 
 $$ = mm_strdup("nowait");
}
|  NULLS_P
 { 
 $$ = mm_strdup("nulls");
}
|  OBJECT_P
 { 
 $$ = mm_strdup("object");
}
|  OF
 { 
 $$ = mm_strdup("of");
}
|  OFF
 { 
 $$ = mm_strdup("off");
}
|  OIDS
 { 
 $$ = mm_strdup("oids");
}
|  OLD
 { 
 $$ = mm_strdup("old");
}
|  OPERATOR
 { 
 $$ = mm_strdup("operator");
}
|  OPTION
 { 
 $$ = mm_strdup("option");
}
|  OPTIONS
 { 
 $$ = mm_strdup("options");
}
|  ORDINALITY
 { 
 $$ = mm_strdup("ordinality");
}
|  OTHERS
 { 
 $$ = mm_strdup("others");
}
|  OVER
 { 
 $$ = mm_strdup("over");
}
|  OVERRIDING
 { 
 $$ = mm_strdup("overriding");
}
|  OWNED
 { 
 $$ = mm_strdup("owned");
}
|  OWNER
 { 
 $$ = mm_strdup("owner");
}
|  PARALLEL
 { 
 $$ = mm_strdup("parallel");
}
|  PARSER
 { 
 $$ = mm_strdup("parser");
}
|  PARTIAL
 { 
 $$ = mm_strdup("partial");
}
|  PARTITION
 { 
 $$ = mm_strdup("partition");
}
|  PASSING
 { 
 $$ = mm_strdup("passing");
}
|  PASSWORD
 { 
 $$ = mm_strdup("password");
}
|  PLANS
 { 
 $$ = mm_strdup("plans");
}
|  POLICY
 { 
 $$ = mm_strdup("policy");
}
|  PRECEDING
 { 
 $$ = mm_strdup("preceding");
}
|  PREPARE
 { 
 $$ = mm_strdup("prepare");
}
|  PREPARED
 { 
 $$ = mm_strdup("prepared");
}
|  PRESERVE
 { 
 $$ = mm_strdup("preserve");
}
|  PRIOR
 { 
 $$ = mm_strdup("prior");
}
|  PRIVILEGES
 { 
 $$ = mm_strdup("privileges");
}
|  PROCEDURAL
 { 
 $$ = mm_strdup("procedural");
}
|  PROCEDURE
 { 
 $$ = mm_strdup("procedure");
}
|  PROCEDURES
 { 
 $$ = mm_strdup("procedures");
}
|  PROGRAM
 { 
 $$ = mm_strdup("program");
}
|  PUBLICATION
 { 
 $$ = mm_strdup("publication");
}
|  QUOTE
 { 
 $$ = mm_strdup("quote");
}
|  RANGE
 { 
 $$ = mm_strdup("range");
}
|  READ
 { 
 $$ = mm_strdup("read");
}
|  REASSIGN
 { 
 $$ = mm_strdup("reassign");
}
|  RECHECK
 { 
 $$ = mm_strdup("recheck");
}
|  RECURSIVE
 { 
 $$ = mm_strdup("recursive");
}
|  REF_P
 { 
 $$ = mm_strdup("ref");
}
|  REFERENCING
 { 
 $$ = mm_strdup("referencing");
}
|  REFRESH
 { 
 $$ = mm_strdup("refresh");
}
|  REINDEX
 { 
 $$ = mm_strdup("reindex");
}
|  RELATIVE_P
 { 
 $$ = mm_strdup("relative");
}
|  RELEASE
 { 
 $$ = mm_strdup("release");
}
|  RENAME
 { 
 $$ = mm_strdup("rename");
}
|  REPEATABLE
 { 
 $$ = mm_strdup("repeatable");
}
|  REPLACE
 { 
 $$ = mm_strdup("replace");
}
|  REPLICA
 { 
 $$ = mm_strdup("replica");
}
|  RESET
 { 
 $$ = mm_strdup("reset");
}
|  RESTART
 { 
 $$ = mm_strdup("restart");
}
|  RESTRICT
 { 
 $$ = mm_strdup("restrict");
}
|  RETURN
 { 
 $$ = mm_strdup("return");
}
|  RETURNS
 { 
 $$ = mm_strdup("returns");
}
|  REVOKE
 { 
 $$ = mm_strdup("revoke");
}
|  ROLE
 { 
 $$ = mm_strdup("role");
}
|  ROLLBACK
 { 
 $$ = mm_strdup("rollback");
}
|  ROLLUP
 { 
 $$ = mm_strdup("rollup");
}
|  ROUTINE
 { 
 $$ = mm_strdup("routine");
}
|  ROUTINES
 { 
 $$ = mm_strdup("routines");
}
|  ROWS
 { 
 $$ = mm_strdup("rows");
}
|  RULE
 { 
 $$ = mm_strdup("rule");
}
|  SAVEPOINT
 { 
 $$ = mm_strdup("savepoint");
}
|  SCHEMA
 { 
 $$ = mm_strdup("schema");
}
|  SCHEMAS
 { 
 $$ = mm_strdup("schemas");
}
|  SCROLL
 { 
 $$ = mm_strdup("scroll");
}
|  SEARCH
 { 
 $$ = mm_strdup("search");
}
|  SECURITY
 { 
 $$ = mm_strdup("security");
}
|  SEQUENCE
 { 
 $$ = mm_strdup("sequence");
}
|  SEQUENCES
 { 
 $$ = mm_strdup("sequences");
}
|  SERIALIZABLE
 { 
 $$ = mm_strdup("serializable");
}
|  SERVER
 { 
 $$ = mm_strdup("server");
}
|  SESSION
 { 
 $$ = mm_strdup("session");
}
|  SET
 { 
 $$ = mm_strdup("set");
}
|  SETS
 { 
 $$ = mm_strdup("sets");
}
|  SHARE
 { 
 $$ = mm_strdup("share");
}
|  SHOW
 { 
 $$ = mm_strdup("show");
}
|  SIMPLE
 { 
 $$ = mm_strdup("simple");
}
|  SKIP
 { 
 $$ = mm_strdup("skip");
}
|  SNAPSHOT
 { 
 $$ = mm_strdup("snapshot");
}
|  SQL_P
 { 
 $$ = mm_strdup("sql");
}
|  STABLE
 { 
 $$ = mm_strdup("stable");
}
|  STANDALONE_P
 { 
 $$ = mm_strdup("standalone");
}
|  START
 { 
 $$ = mm_strdup("start");
}
|  STATEMENT
 { 
 $$ = mm_strdup("statement");
}
|  STATISTICS
 { 
 $$ = mm_strdup("statistics");
}
|  STDIN
 { 
 $$ = mm_strdup("stdin");
}
|  STDOUT
 { 
 $$ = mm_strdup("stdout");
}
|  STORAGE
 { 
 $$ = mm_strdup("storage");
}
|  STORED
 { 
 $$ = mm_strdup("stored");
}
|  STRICT_P
 { 
 $$ = mm_strdup("strict");
}
|  STRIP_P
 { 
 $$ = mm_strdup("strip");
}
|  SUBSCRIPTION
 { 
 $$ = mm_strdup("subscription");
}
|  SUPPORT
 { 
 $$ = mm_strdup("support");
}
|  SYSID
 { 
 $$ = mm_strdup("sysid");
}
|  SYSTEM_P
 { 
 $$ = mm_strdup("system");
}
|  TABLES
 { 
 $$ = mm_strdup("tables");
}
|  TABLESPACE
 { 
 $$ = mm_strdup("tablespace");
}
|  TEMP
 { 
 $$ = mm_strdup("temp");
}
|  TEMPLATE
 { 
 $$ = mm_strdup("template");
}
|  TEMPORARY
 { 
 $$ = mm_strdup("temporary");
}
|  TEXT_P
 { 
 $$ = mm_strdup("text");
}
|  TIES
 { 
 $$ = mm_strdup("ties");
}
|  TRANSACTION
 { 
 $$ = mm_strdup("transaction");
}
|  TRANSFORM
 { 
 $$ = mm_strdup("transform");
}
|  TRIGGER
 { 
 $$ = mm_strdup("trigger");
}
|  TRUNCATE
 { 
 $$ = mm_strdup("truncate");
}
|  TRUSTED
 { 
 $$ = mm_strdup("trusted");
}
|  TYPE_P
 { 
 $$ = mm_strdup("type");
}
|  TYPES_P
 { 
 $$ = mm_strdup("types");
}
|  UESCAPE
 { 
 $$ = mm_strdup("uescape");
}
|  UNBOUNDED
 { 
 $$ = mm_strdup("unbounded");
}
|  UNCOMMITTED
 { 
 $$ = mm_strdup("uncommitted");
}
|  UNENCRYPTED
 { 
 $$ = mm_strdup("unencrypted");
}
|  UNKNOWN
 { 
 $$ = mm_strdup("unknown");
}
|  UNLISTEN
 { 
 $$ = mm_strdup("unlisten");
}
|  UNLOGGED
 { 
 $$ = mm_strdup("unlogged");
}
|  UNTIL
 { 
 $$ = mm_strdup("until");
}
|  UPDATE
 { 
 $$ = mm_strdup("update");
}
|  VACUUM
 { 
 $$ = mm_strdup("vacuum");
}
|  VALID
 { 
 $$ = mm_strdup("valid");
}
|  VALIDATE
 { 
 $$ = mm_strdup("validate");
}
|  VALIDATOR
 { 
 $$ = mm_strdup("validator");
}
|  VALUE_P
 { 
 $$ = mm_strdup("value");
}
|  VARYING
 { 
 $$ = mm_strdup("varying");
}
|  VERSION_P
 { 
 $$ = mm_strdup("version");
}
|  VIEW
 { 
 $$ = mm_strdup("view");
}
|  VIEWS
 { 
 $$ = mm_strdup("views");
}
|  VOLATILE
 { 
 $$ = mm_strdup("volatile");
}
|  WHITESPACE_P
 { 
 $$ = mm_strdup("whitespace");
}
|  WITHIN
 { 
 $$ = mm_strdup("within");
}
|  WITHOUT
 { 
 $$ = mm_strdup("without");
}
|  WORK
 { 
 $$ = mm_strdup("work");
}
|  WRAPPER
 { 
 $$ = mm_strdup("wrapper");
}
|  WRITE
 { 
 $$ = mm_strdup("write");
}
|  XML_P
 { 
 $$ = mm_strdup("xml");
}
|  YES_P
 { 
 $$ = mm_strdup("yes");
}
|  ZONE
 { 
 $$ = mm_strdup("zone");
}
;


 col_name_keyword:
 BETWEEN
 { 
 $$ = mm_strdup("between");
}
|  BIGINT
 { 
 $$ = mm_strdup("bigint");
}
|  BIT
 { 
 $$ = mm_strdup("bit");
}
|  BOOLEAN_P
 { 
 $$ = mm_strdup("boolean");
}
|  CHARACTER
 { 
 $$ = mm_strdup("character");
}
|  COALESCE
 { 
 $$ = mm_strdup("coalesce");
}
|  DEC
 { 
 $$ = mm_strdup("dec");
}
|  DECIMAL_P
 { 
 $$ = mm_strdup("decimal");
}
|  EXISTS
 { 
 $$ = mm_strdup("exists");
}
|  EXTRACT
 { 
 $$ = mm_strdup("extract");
}
|  FLOAT_P
 { 
 $$ = mm_strdup("float");
}
|  GREATEST
 { 
 $$ = mm_strdup("greatest");
}
|  GROUPING
 { 
 $$ = mm_strdup("grouping");
}
|  INOUT
 { 
 $$ = mm_strdup("inout");
}
|  INTEGER
 { 
 $$ = mm_strdup("integer");
}
|  INTERVAL
 { 
 $$ = mm_strdup("interval");
}
|  LEAST
 { 
 $$ = mm_strdup("least");
}
|  NATIONAL
 { 
 $$ = mm_strdup("national");
}
|  NCHAR
 { 
 $$ = mm_strdup("nchar");
}
|  NONE
 { 
 $$ = mm_strdup("none");
}
|  NORMALIZE
 { 
 $$ = mm_strdup("normalize");
}
|  NULLIF
 { 
 $$ = mm_strdup("nullif");
}
|  NUMERIC
 { 
 $$ = mm_strdup("numeric");
}
|  OUT_P
 { 
 $$ = mm_strdup("out");
}
|  OVERLAY
 { 
 $$ = mm_strdup("overlay");
}
|  POSITION
 { 
 $$ = mm_strdup("position");
}
|  PRECISION
 { 
 $$ = mm_strdup("precision");
}
|  REAL
 { 
 $$ = mm_strdup("real");
}
|  ROW
 { 
 $$ = mm_strdup("row");
}
|  SETOF
 { 
 $$ = mm_strdup("setof");
}
|  SMALLINT
 { 
 $$ = mm_strdup("smallint");
}
|  SUBSTRING
 { 
 $$ = mm_strdup("substring");
}
|  TIME
 { 
 $$ = mm_strdup("time");
}
|  TIMESTAMP
 { 
 $$ = mm_strdup("timestamp");
}
|  TREAT
 { 
 $$ = mm_strdup("treat");
}
|  TRIM
 { 
 $$ = mm_strdup("trim");
}
|  VARCHAR
 { 
 $$ = mm_strdup("varchar");
}
|  XMLATTRIBUTES
 { 
 $$ = mm_strdup("xmlattributes");
}
|  XMLCONCAT
 { 
 $$ = mm_strdup("xmlconcat");
}
|  XMLELEMENT
 { 
 $$ = mm_strdup("xmlelement");
}
|  XMLEXISTS
 { 
 $$ = mm_strdup("xmlexists");
}
|  XMLFOREST
 { 
 $$ = mm_strdup("xmlforest");
}
|  XMLNAMESPACES
 { 
 $$ = mm_strdup("xmlnamespaces");
}
|  XMLPARSE
 { 
 $$ = mm_strdup("xmlparse");
}
|  XMLPI
 { 
 $$ = mm_strdup("xmlpi");
}
|  XMLROOT
 { 
 $$ = mm_strdup("xmlroot");
}
|  XMLSERIALIZE
 { 
 $$ = mm_strdup("xmlserialize");
}
|  XMLTABLE
 { 
 $$ = mm_strdup("xmltable");
}
;


 type_func_name_keyword:
 AUTHORIZATION
 { 
 $$ = mm_strdup("authorization");
}
|  BINARY
 { 
 $$ = mm_strdup("binary");
}
|  COLLATION
 { 
 $$ = mm_strdup("collation");
}
|  CONCURRENTLY
 { 
 $$ = mm_strdup("concurrently");
}
|  CROSS
 { 
 $$ = mm_strdup("cross");
}
|  CURRENT_SCHEMA
 { 
 $$ = mm_strdup("current_schema");
}
|  FREEZE
 { 
 $$ = mm_strdup("freeze");
}
|  FULL
 { 
 $$ = mm_strdup("full");
}
|  ILIKE
 { 
 $$ = mm_strdup("ilike");
}
|  INNER_P
 { 
 $$ = mm_strdup("inner");
}
|  IS
 { 
 $$ = mm_strdup("is");
}
|  ISNULL
 { 
 $$ = mm_strdup("isnull");
}
|  JOIN
 { 
 $$ = mm_strdup("join");
}
|  LEFT
 { 
 $$ = mm_strdup("left");
}
|  LIKE
 { 
 $$ = mm_strdup("like");
}
|  NATURAL
 { 
 $$ = mm_strdup("natural");
}
|  NOTNULL
 { 
 $$ = mm_strdup("notnull");
}
|  OUTER_P
 { 
 $$ = mm_strdup("outer");
}
|  OVERLAPS
 { 
 $$ = mm_strdup("overlaps");
}
|  RIGHT
 { 
 $$ = mm_strdup("right");
}
|  SIMILAR
 { 
 $$ = mm_strdup("similar");
}
|  TABLESAMPLE
 { 
 $$ = mm_strdup("tablesample");
}
|  VERBOSE
 { 
 $$ = mm_strdup("verbose");
}
;


 reserved_keyword:
 ALL
 { 
 $$ = mm_strdup("all");
}
|  ANALYSE
 { 
 $$ = mm_strdup("analyse");
}
|  ANALYZE
 { 
 $$ = mm_strdup("analyze");
}
|  AND
 { 
 $$ = mm_strdup("and");
}
|  ANY
 { 
 $$ = mm_strdup("any");
}
|  ARRAY
 { 
 $$ = mm_strdup("array");
}
|  AS
 { 
 $$ = mm_strdup("as");
}
|  ASC
 { 
 $$ = mm_strdup("asc");
}
|  ASYMMETRIC
 { 
 $$ = mm_strdup("asymmetric");
}
|  BOTH
 { 
 $$ = mm_strdup("both");
}
|  CASE
 { 
 $$ = mm_strdup("case");
}
|  CAST
 { 
 $$ = mm_strdup("cast");
}
|  CHECK
 { 
 $$ = mm_strdup("check");
}
|  COLLATE
 { 
 $$ = mm_strdup("collate");
}
|  COLUMN
 { 
 $$ = mm_strdup("column");
}
|  CONSTRAINT
 { 
 $$ = mm_strdup("constraint");
}
|  CREATE
 { 
 $$ = mm_strdup("create");
}
|  CURRENT_CATALOG
 { 
 $$ = mm_strdup("current_catalog");
}
|  CURRENT_DATE
 { 
 $$ = mm_strdup("current_date");
}
|  CURRENT_ROLE
 { 
 $$ = mm_strdup("current_role");
}
|  CURRENT_TIME
 { 
 $$ = mm_strdup("current_time");
}
|  CURRENT_TIMESTAMP
 { 
 $$ = mm_strdup("current_timestamp");
}
|  CURRENT_USER
 { 
 $$ = mm_strdup("current_user");
}
|  DEFAULT
 { 
 $$ = mm_strdup("default");
}
|  DEFERRABLE
 { 
 $$ = mm_strdup("deferrable");
}
|  DESC
 { 
 $$ = mm_strdup("desc");
}
|  DISTINCT
 { 
 $$ = mm_strdup("distinct");
}
|  DO
 { 
 $$ = mm_strdup("do");
}
|  ELSE
 { 
 $$ = mm_strdup("else");
}
|  END_P
 { 
 $$ = mm_strdup("end");
}
|  EXCEPT
 { 
 $$ = mm_strdup("except");
}
|  FALSE_P
 { 
 $$ = mm_strdup("false");
}
|  FETCH
 { 
 $$ = mm_strdup("fetch");
}
|  FOR
 { 
 $$ = mm_strdup("for");
}
|  FOREIGN
 { 
 $$ = mm_strdup("foreign");
}
|  FROM
 { 
 $$ = mm_strdup("from");
}
|  GRANT
 { 
 $$ = mm_strdup("grant");
}
|  GROUP_P
 { 
 $$ = mm_strdup("group");
}
|  HAVING
 { 
 $$ = mm_strdup("having");
}
|  IN_P
 { 
 $$ = mm_strdup("in");
}
|  INITIALLY
 { 
 $$ = mm_strdup("initially");
}
|  INTERSECT
 { 
 $$ = mm_strdup("intersect");
}
|  INTO
 { 
 $$ = mm_strdup("into");
}
|  LATERAL_P
 { 
 $$ = mm_strdup("lateral");
}
|  LEADING
 { 
 $$ = mm_strdup("leading");
}
|  LIMIT
 { 
 $$ = mm_strdup("limit");
}
|  LOCALTIME
 { 
 $$ = mm_strdup("localtime");
}
|  LOCALTIMESTAMP
 { 
 $$ = mm_strdup("localtimestamp");
}
|  NOT
 { 
 $$ = mm_strdup("not");
}
|  NULL_P
 { 
 $$ = mm_strdup("null");
}
|  OFFSET
 { 
 $$ = mm_strdup("offset");
}
|  ON
 { 
 $$ = mm_strdup("on");
}
|  ONLY
 { 
 $$ = mm_strdup("only");
}
|  OR
 { 
 $$ = mm_strdup("or");
}
|  ORDER
 { 
 $$ = mm_strdup("order");
}
|  PLACING
 { 
 $$ = mm_strdup("placing");
}
|  PRIMARY
 { 
 $$ = mm_strdup("primary");
}
|  REFERENCES
 { 
 $$ = mm_strdup("references");
}
|  RETURNING
 { 
 $$ = mm_strdup("returning");
}
|  SELECT
 { 
 $$ = mm_strdup("select");
}
|  SESSION_USER
 { 
 $$ = mm_strdup("session_user");
}
|  SOME
 { 
 $$ = mm_strdup("some");
}
|  SYMMETRIC
 { 
 $$ = mm_strdup("symmetric");
}
|  TABLE
 { 
 $$ = mm_strdup("table");
}
|  THEN
 { 
 $$ = mm_strdup("then");
}
|  TRAILING
 { 
 $$ = mm_strdup("trailing");
}
|  TRUE_P
 { 
 $$ = mm_strdup("true");
}
|  UNIQUE
 { 
 $$ = mm_strdup("unique");
}
|  USER
 { 
 $$ = mm_strdup("user");
}
|  USING
 { 
 $$ = mm_strdup("using");
}
|  VARIADIC
 { 
 $$ = mm_strdup("variadic");
}
|  WHEN
 { 
 $$ = mm_strdup("when");
}
|  WHERE
 { 
 $$ = mm_strdup("where");
}
|  WINDOW
 { 
 $$ = mm_strdup("window");
}
|  WITH
 { 
 $$ = mm_strdup("with");
}
;


 bare_label_keyword:
 ABORT_P
 { 
 $$ = mm_strdup("abort");
}
|  ABSOLUTE_P
 { 
 $$ = mm_strdup("absolute");
}
|  ACCESS
 { 
 $$ = mm_strdup("access");
}
|  ACTION
 { 
 $$ = mm_strdup("action");
}
|  ADD_P
 { 
 $$ = mm_strdup("add");
}
|  ADMIN
 { 
 $$ = mm_strdup("admin");
}
|  AFTER
 { 
 $$ = mm_strdup("after");
}
|  AGGREGATE
 { 
 $$ = mm_strdup("aggregate");
}
|  ALL
 { 
 $$ = mm_strdup("all");
}
|  ALSO
 { 
 $$ = mm_strdup("also");
}
|  ALTER
 { 
 $$ = mm_strdup("alter");
}
|  ALWAYS
 { 
 $$ = mm_strdup("always");
}
|  ANALYSE
 { 
 $$ = mm_strdup("analyse");
}
|  ANALYZE
 { 
 $$ = mm_strdup("analyze");
}
|  AND
 { 
 $$ = mm_strdup("and");
}
|  ANY
 { 
 $$ = mm_strdup("any");
}
|  ASC
 { 
 $$ = mm_strdup("asc");
}
|  ASENSITIVE
 { 
 $$ = mm_strdup("asensitive");
}
|  ASSERTION
 { 
 $$ = mm_strdup("assertion");
}
|  ASSIGNMENT
 { 
 $$ = mm_strdup("assignment");
}
|  ASYMMETRIC
 { 
 $$ = mm_strdup("asymmetric");
}
|  AT
 { 
 $$ = mm_strdup("at");
}
|  ATOMIC
 { 
 $$ = mm_strdup("atomic");
}
|  ATTACH
 { 
 $$ = mm_strdup("attach");
}
|  ATTRIBUTE
 { 
 $$ = mm_strdup("attribute");
}
|  AUTHORIZATION
 { 
 $$ = mm_strdup("authorization");
}
|  BACKWARD
 { 
 $$ = mm_strdup("backward");
}
|  BEFORE
 { 
 $$ = mm_strdup("before");
}
|  BEGIN_P
 { 
 $$ = mm_strdup("begin");
}
|  BETWEEN
 { 
 $$ = mm_strdup("between");
}
|  BIGINT
 { 
 $$ = mm_strdup("bigint");
}
|  BINARY
 { 
 $$ = mm_strdup("binary");
}
|  BIT
 { 
 $$ = mm_strdup("bit");
}
|  BOOLEAN_P
 { 
 $$ = mm_strdup("boolean");
}
|  BOTH
 { 
 $$ = mm_strdup("both");
}
|  BREADTH
 { 
 $$ = mm_strdup("breadth");
}
|  BY
 { 
 $$ = mm_strdup("by");
}
|  CACHE
 { 
 $$ = mm_strdup("cache");
}
|  CALL
 { 
 $$ = mm_strdup("call");
}
|  CALLED
 { 
 $$ = mm_strdup("called");
}
|  CASCADE
 { 
 $$ = mm_strdup("cascade");
}
|  CASCADED
 { 
 $$ = mm_strdup("cascaded");
}
|  CASE
 { 
 $$ = mm_strdup("case");
}
|  CAST
 { 
 $$ = mm_strdup("cast");
}
|  CATALOG_P
 { 
 $$ = mm_strdup("catalog");
}
|  CHAIN
 { 
 $$ = mm_strdup("chain");
}
|  CHARACTERISTICS
 { 
 $$ = mm_strdup("characteristics");
}
|  CHECK
 { 
 $$ = mm_strdup("check");
}
|  CHECKPOINT
 { 
 $$ = mm_strdup("checkpoint");
}
|  CLASS
 { 
 $$ = mm_strdup("class");
}
|  CLOSE
 { 
 $$ = mm_strdup("close");
}
|  CLUSTER
 { 
 $$ = mm_strdup("cluster");
}
|  COALESCE
 { 
 $$ = mm_strdup("coalesce");
}
|  COLLATE
 { 
 $$ = mm_strdup("collate");
}
|  COLLATION
 { 
 $$ = mm_strdup("collation");
}
|  COLUMN
 { 
 $$ = mm_strdup("column");
}
|  COLUMNS
 { 
 $$ = mm_strdup("columns");
}
|  COMMENT
 { 
 $$ = mm_strdup("comment");
}
|  COMMENTS
 { 
 $$ = mm_strdup("comments");
}
|  COMMIT
 { 
 $$ = mm_strdup("commit");
}
|  COMMITTED
 { 
 $$ = mm_strdup("committed");
}
|  COMPRESSION
 { 
 $$ = mm_strdup("compression");
}
|  CONCURRENTLY
 { 
 $$ = mm_strdup("concurrently");
}
|  CONFIGURATION
 { 
 $$ = mm_strdup("configuration");
}
|  CONFLICT
 { 
 $$ = mm_strdup("conflict");
}
|  CONNECTION
 { 
 $$ = mm_strdup("connection");
}
|  CONSTRAINT
 { 
 $$ = mm_strdup("constraint");
}
|  CONSTRAINTS
 { 
 $$ = mm_strdup("constraints");
}
|  CONTENT_P
 { 
 $$ = mm_strdup("content");
}
|  CONTINUE_P
 { 
 $$ = mm_strdup("continue");
}
|  CONVERSION_P
 { 
 $$ = mm_strdup("conversion");
}
|  COPY
 { 
 $$ = mm_strdup("copy");
}
|  COST
 { 
 $$ = mm_strdup("cost");
}
|  CROSS
 { 
 $$ = mm_strdup("cross");
}
|  CSV
 { 
 $$ = mm_strdup("csv");
}
|  CUBE
 { 
 $$ = mm_strdup("cube");
}
|  CURRENT_P
 { 
 $$ = mm_strdup("current");
}
|  CURRENT_CATALOG
 { 
 $$ = mm_strdup("current_catalog");
}
|  CURRENT_DATE
 { 
 $$ = mm_strdup("current_date");
}
|  CURRENT_ROLE
 { 
 $$ = mm_strdup("current_role");
}
|  CURRENT_SCHEMA
 { 
 $$ = mm_strdup("current_schema");
}
|  CURRENT_TIME
 { 
 $$ = mm_strdup("current_time");
}
|  CURRENT_TIMESTAMP
 { 
 $$ = mm_strdup("current_timestamp");
}
|  CURRENT_USER
 { 
 $$ = mm_strdup("current_user");
}
|  CURSOR
 { 
 $$ = mm_strdup("cursor");
}
|  CYCLE
 { 
 $$ = mm_strdup("cycle");
}
|  DATA_P
 { 
 $$ = mm_strdup("data");
}
|  DATABASE
 { 
 $$ = mm_strdup("database");
}
|  DEALLOCATE
 { 
 $$ = mm_strdup("deallocate");
}
|  DEC
 { 
 $$ = mm_strdup("dec");
}
|  DECIMAL_P
 { 
 $$ = mm_strdup("decimal");
}
|  DECLARE
 { 
 $$ = mm_strdup("declare");
}
|  DEFAULT
 { 
 $$ = mm_strdup("default");
}
|  DEFAULTS
 { 
 $$ = mm_strdup("defaults");
}
|  DEFERRABLE
 { 
 $$ = mm_strdup("deferrable");
}
|  DEFERRED
 { 
 $$ = mm_strdup("deferred");
}
|  DEFINER
 { 
 $$ = mm_strdup("definer");
}
|  DELETE_P
 { 
 $$ = mm_strdup("delete");
}
|  DELIMITER
 { 
 $$ = mm_strdup("delimiter");
}
|  DELIMITERS
 { 
 $$ = mm_strdup("delimiters");
}
|  DEPENDS
 { 
 $$ = mm_strdup("depends");
}
|  DEPTH
 { 
 $$ = mm_strdup("depth");
}
|  DESC
 { 
 $$ = mm_strdup("desc");
}
|  DETACH
 { 
 $$ = mm_strdup("detach");
}
|  DICTIONARY
 { 
 $$ = mm_strdup("dictionary");
}
|  DISABLE_P
 { 
 $$ = mm_strdup("disable");
}
|  DISCARD
 { 
 $$ = mm_strdup("discard");
}
|  DISTINCT
 { 
 $$ = mm_strdup("distinct");
}
|  DO
 { 
 $$ = mm_strdup("do");
}
|  DOCUMENT_P
 { 
 $$ = mm_strdup("document");
}
|  DOMAIN_P
 { 
 $$ = mm_strdup("domain");
}
|  DOUBLE_P
 { 
 $$ = mm_strdup("double");
}
|  DROP
 { 
 $$ = mm_strdup("drop");
}
|  EACH
 { 
 $$ = mm_strdup("each");
}
|  ELSE
 { 
 $$ = mm_strdup("else");
}
|  ENABLE_P
 { 
 $$ = mm_strdup("enable");
}
|  ENCODING
 { 
 $$ = mm_strdup("encoding");
}
|  ENCRYPTED
 { 
 $$ = mm_strdup("encrypted");
}
|  END_P
 { 
 $$ = mm_strdup("end");
}
|  ENUM_P
 { 
 $$ = mm_strdup("enum");
}
|  ESCAPE
 { 
 $$ = mm_strdup("escape");
}
|  EVENT
 { 
 $$ = mm_strdup("event");
}
|  EXCLUDE
 { 
 $$ = mm_strdup("exclude");
}
|  EXCLUDING
 { 
 $$ = mm_strdup("excluding");
}
|  EXCLUSIVE
 { 
 $$ = mm_strdup("exclusive");
}
|  EXECUTE
 { 
 $$ = mm_strdup("execute");
}
|  EXISTS
 { 
 $$ = mm_strdup("exists");
}
|  EXPLAIN
 { 
 $$ = mm_strdup("explain");
}
|  EXPRESSION
 { 
 $$ = mm_strdup("expression");
}
|  EXTENSION
 { 
 $$ = mm_strdup("extension");
}
|  EXTERNAL
 { 
 $$ = mm_strdup("external");
}
|  EXTRACT
 { 
 $$ = mm_strdup("extract");
}
|  FALSE_P
 { 
 $$ = mm_strdup("false");
}
|  FAMILY
 { 
 $$ = mm_strdup("family");
}
|  FINALIZE
 { 
 $$ = mm_strdup("finalize");
}
|  FIRST_P
 { 
 $$ = mm_strdup("first");
}
|  FLOAT_P
 { 
 $$ = mm_strdup("float");
}
|  FOLLOWING
 { 
 $$ = mm_strdup("following");
}
|  FORCE
 { 
 $$ = mm_strdup("force");
}
|  FOREIGN
 { 
 $$ = mm_strdup("foreign");
}
|  FORWARD
 { 
 $$ = mm_strdup("forward");
}
|  FREEZE
 { 
 $$ = mm_strdup("freeze");
}
|  FULL
 { 
 $$ = mm_strdup("full");
}
|  FUNCTION
 { 
 $$ = mm_strdup("function");
}
|  FUNCTIONS
 { 
 $$ = mm_strdup("functions");
}
|  GENERATED
 { 
 $$ = mm_strdup("generated");
}
|  GLOBAL
 { 
 $$ = mm_strdup("global");
}
|  GRANTED
 { 
 $$ = mm_strdup("granted");
}
|  GREATEST
 { 
 $$ = mm_strdup("greatest");
}
|  GROUPING
 { 
 $$ = mm_strdup("grouping");
}
|  GROUPS
 { 
 $$ = mm_strdup("groups");
}
|  HANDLER
 { 
 $$ = mm_strdup("handler");
}
|  HEADER_P
 { 
 $$ = mm_strdup("header");
}
|  HOLD
 { 
 $$ = mm_strdup("hold");
}
|  IDENTITY_P
 { 
 $$ = mm_strdup("identity");
}
|  IF_P
 { 
 $$ = mm_strdup("if");
}
|  ILIKE
 { 
 $$ = mm_strdup("ilike");
}
|  IMMEDIATE
 { 
 $$ = mm_strdup("immediate");
}
|  IMMUTABLE
 { 
 $$ = mm_strdup("immutable");
}
|  IMPLICIT_P
 { 
 $$ = mm_strdup("implicit");
}
|  IMPORT_P
 { 
 $$ = mm_strdup("import");
}
|  IN_P
 { 
 $$ = mm_strdup("in");
}
|  INCLUDE
 { 
 $$ = mm_strdup("include");
}
|  INCLUDING
 { 
 $$ = mm_strdup("including");
}
|  INCREMENT
 { 
 $$ = mm_strdup("increment");
}
|  INDEX
 { 
 $$ = mm_strdup("index");
}
|  INDEXES
 { 
 $$ = mm_strdup("indexes");
}
|  INHERIT
 { 
 $$ = mm_strdup("inherit");
}
|  INHERITS
 { 
 $$ = mm_strdup("inherits");
}
|  INITIALLY
 { 
 $$ = mm_strdup("initially");
}
|  INLINE_P
 { 
 $$ = mm_strdup("inline");
}
|  INNER_P
 { 
 $$ = mm_strdup("inner");
}
|  INOUT
 { 
 $$ = mm_strdup("inout");
}
|  INPUT_P
 { 
 $$ = mm_strdup("input");
}
|  INSENSITIVE
 { 
 $$ = mm_strdup("insensitive");
}
|  INSERT
 { 
 $$ = mm_strdup("insert");
}
|  INSTEAD
 { 
 $$ = mm_strdup("instead");
}
|  INT_P
 { 
 $$ = mm_strdup("int");
}
|  INTEGER
 { 
 $$ = mm_strdup("integer");
}
|  INTERVAL
 { 
 $$ = mm_strdup("interval");
}
|  INVOKER
 { 
 $$ = mm_strdup("invoker");
}
|  IS
 { 
 $$ = mm_strdup("is");
}
|  ISOLATION
 { 
 $$ = mm_strdup("isolation");
}
|  JOIN
 { 
 $$ = mm_strdup("join");
}
|  KEY
 { 
 $$ = mm_strdup("key");
}
|  LABEL
 { 
 $$ = mm_strdup("label");
}
|  LANGUAGE
 { 
 $$ = mm_strdup("language");
}
|  LARGE_P
 { 
 $$ = mm_strdup("large");
}
|  LAST_P
 { 
 $$ = mm_strdup("last");
}
|  LATERAL_P
 { 
 $$ = mm_strdup("lateral");
}
|  LEADING
 { 
 $$ = mm_strdup("leading");
}
|  LEAKPROOF
 { 
 $$ = mm_strdup("leakproof");
}
|  LEAST
 { 
 $$ = mm_strdup("least");
}
|  LEFT
 { 
 $$ = mm_strdup("left");
}
|  LEVEL
 { 
 $$ = mm_strdup("level");
}
|  LIKE
 { 
 $$ = mm_strdup("like");
}
|  LISTEN
 { 
 $$ = mm_strdup("listen");
}
|  LOAD
 { 
 $$ = mm_strdup("load");
}
|  LOCAL
 { 
 $$ = mm_strdup("local");
}
|  LOCALTIME
 { 
 $$ = mm_strdup("localtime");
}
|  LOCALTIMESTAMP
 { 
 $$ = mm_strdup("localtimestamp");
}
|  LOCATION
 { 
 $$ = mm_strdup("location");
}
|  LOCK_P
 { 
 $$ = mm_strdup("lock");
}
|  LOCKED
 { 
 $$ = mm_strdup("locked");
}
|  LOGGED
 { 
 $$ = mm_strdup("logged");
}
|  MAPPING
 { 
 $$ = mm_strdup("mapping");
}
|  MATCH
 { 
 $$ = mm_strdup("match");
}
|  MATERIALIZED
 { 
 $$ = mm_strdup("materialized");
}
|  MAXVALUE
 { 
 $$ = mm_strdup("maxvalue");
}
|  METHOD
 { 
 $$ = mm_strdup("method");
}
|  MINVALUE
 { 
 $$ = mm_strdup("minvalue");
}
|  MODE
 { 
 $$ = mm_strdup("mode");
}
|  MOVE
 { 
 $$ = mm_strdup("move");
}
|  NAME_P
 { 
 $$ = mm_strdup("name");
}
|  NAMES
 { 
 $$ = mm_strdup("names");
}
|  NATIONAL
 { 
 $$ = mm_strdup("national");
}
|  NATURAL
 { 
 $$ = mm_strdup("natural");
}
|  NCHAR
 { 
 $$ = mm_strdup("nchar");
}
|  NEW
 { 
 $$ = mm_strdup("new");
}
|  NEXT
 { 
 $$ = mm_strdup("next");
}
|  NFC
 { 
 $$ = mm_strdup("nfc");
}
|  NFD
 { 
 $$ = mm_strdup("nfd");
}
|  NFKC
 { 
 $$ = mm_strdup("nfkc");
}
|  NFKD
 { 
 $$ = mm_strdup("nfkd");
}
|  NO
 { 
 $$ = mm_strdup("no");
}
|  NONE
 { 
 $$ = mm_strdup("none");
}
|  NORMALIZE
 { 
 $$ = mm_strdup("normalize");
}
|  NORMALIZED
 { 
 $$ = mm_strdup("normalized");
}
|  NOT
 { 
 $$ = mm_strdup("not");
}
|  NOTHING
 { 
 $$ = mm_strdup("nothing");
}
|  NOTIFY
 { 
 $$ = mm_strdup("notify");
}
|  NOWAIT
 { 
 $$ = mm_strdup("nowait");
}
|  NULL_P
 { 
 $$ = mm_strdup("null");
}
|  NULLIF
 { 
 $$ = mm_strdup("nullif");
}
|  NULLS_P
 { 
 $$ = mm_strdup("nulls");
}
|  NUMERIC
 { 
 $$ = mm_strdup("numeric");
}
|  OBJECT_P
 { 
 $$ = mm_strdup("object");
}
|  OF
 { 
 $$ = mm_strdup("of");
}
|  OFF
 { 
 $$ = mm_strdup("off");
}
|  OIDS
 { 
 $$ = mm_strdup("oids");
}
|  OLD
 { 
 $$ = mm_strdup("old");
}
|  ONLY
 { 
 $$ = mm_strdup("only");
}
|  OPERATOR
 { 
 $$ = mm_strdup("operator");
}
|  OPTION
 { 
 $$ = mm_strdup("option");
}
|  OPTIONS
 { 
 $$ = mm_strdup("options");
}
|  OR
 { 
 $$ = mm_strdup("or");
}
|  ORDINALITY
 { 
 $$ = mm_strdup("ordinality");
}
|  OTHERS
 { 
 $$ = mm_strdup("others");
}
|  OUT_P
 { 
 $$ = mm_strdup("out");
}
|  OUTER_P
 { 
 $$ = mm_strdup("outer");
}
|  OVERLAY
 { 
 $$ = mm_strdup("overlay");
}
|  OVERRIDING
 { 
 $$ = mm_strdup("overriding");
}
|  OWNED
 { 
 $$ = mm_strdup("owned");
}
|  OWNER
 { 
 $$ = mm_strdup("owner");
}
|  PARALLEL
 { 
 $$ = mm_strdup("parallel");
}
|  PARSER
 { 
 $$ = mm_strdup("parser");
}
|  PARTIAL
 { 
 $$ = mm_strdup("partial");
}
|  PARTITION
 { 
 $$ = mm_strdup("partition");
}
|  PASSING
 { 
 $$ = mm_strdup("passing");
}
|  PASSWORD
 { 
 $$ = mm_strdup("password");
}
|  PLACING
 { 
 $$ = mm_strdup("placing");
}
|  PLANS
 { 
 $$ = mm_strdup("plans");
}
|  POLICY
 { 
 $$ = mm_strdup("policy");
}
|  POSITION
 { 
 $$ = mm_strdup("position");
}
|  PRECEDING
 { 
 $$ = mm_strdup("preceding");
}
|  PREPARE
 { 
 $$ = mm_strdup("prepare");
}
|  PREPARED
 { 
 $$ = mm_strdup("prepared");
}
|  PRESERVE
 { 
 $$ = mm_strdup("preserve");
}
|  PRIMARY
 { 
 $$ = mm_strdup("primary");
}
|  PRIOR
 { 
 $$ = mm_strdup("prior");
}
|  PRIVILEGES
 { 
 $$ = mm_strdup("privileges");
}
|  PROCEDURAL
 { 
 $$ = mm_strdup("procedural");
}
|  PROCEDURE
 { 
 $$ = mm_strdup("procedure");
}
|  PROCEDURES
 { 
 $$ = mm_strdup("procedures");
}
|  PROGRAM
 { 
 $$ = mm_strdup("program");
}
|  PUBLICATION
 { 
 $$ = mm_strdup("publication");
}
|  QUOTE
 { 
 $$ = mm_strdup("quote");
}
|  RANGE
 { 
 $$ = mm_strdup("range");
}
|  READ
 { 
 $$ = mm_strdup("read");
}
|  REAL
 { 
 $$ = mm_strdup("real");
}
|  REASSIGN
 { 
 $$ = mm_strdup("reassign");
}
|  RECHECK
 { 
 $$ = mm_strdup("recheck");
}
|  RECURSIVE
 { 
 $$ = mm_strdup("recursive");
}
|  REF_P
 { 
 $$ = mm_strdup("ref");
}
|  REFERENCES
 { 
 $$ = mm_strdup("references");
}
|  REFERENCING
 { 
 $$ = mm_strdup("referencing");
}
|  REFRESH
 { 
 $$ = mm_strdup("refresh");
}
|  REINDEX
 { 
 $$ = mm_strdup("reindex");
}
|  RELATIVE_P
 { 
 $$ = mm_strdup("relative");
}
|  RELEASE
 { 
 $$ = mm_strdup("release");
}
|  RENAME
 { 
 $$ = mm_strdup("rename");
}
|  REPEATABLE
 { 
 $$ = mm_strdup("repeatable");
}
|  REPLACE
 { 
 $$ = mm_strdup("replace");
}
|  REPLICA
 { 
 $$ = mm_strdup("replica");
}
|  RESET
 { 
 $$ = mm_strdup("reset");
}
|  RESTART
 { 
 $$ = mm_strdup("restart");
}
|  RESTRICT
 { 
 $$ = mm_strdup("restrict");
}
|  RETURN
 { 
 $$ = mm_strdup("return");
}
|  RETURNS
 { 
 $$ = mm_strdup("returns");
}
|  REVOKE
 { 
 $$ = mm_strdup("revoke");
}
|  RIGHT
 { 
 $$ = mm_strdup("right");
}
|  ROLE
 { 
 $$ = mm_strdup("role");
}
|  ROLLBACK
 { 
 $$ = mm_strdup("rollback");
}
|  ROLLUP
 { 
 $$ = mm_strdup("rollup");
}
|  ROUTINE
 { 
 $$ = mm_strdup("routine");
}
|  ROUTINES
 { 
 $$ = mm_strdup("routines");
}
|  ROW
 { 
 $$ = mm_strdup("row");
}
|  ROWS
 { 
 $$ = mm_strdup("rows");
}
|  RULE
 { 
 $$ = mm_strdup("rule");
}
|  SAVEPOINT
 { 
 $$ = mm_strdup("savepoint");
}
|  SCHEMA
 { 
 $$ = mm_strdup("schema");
}
|  SCHEMAS
 { 
 $$ = mm_strdup("schemas");
}
|  SCROLL
 { 
 $$ = mm_strdup("scroll");
}
|  SEARCH
 { 
 $$ = mm_strdup("search");
}
|  SECURITY
 { 
 $$ = mm_strdup("security");
}
|  SELECT
 { 
 $$ = mm_strdup("select");
}
|  SEQUENCE
 { 
 $$ = mm_strdup("sequence");
}
|  SEQUENCES
 { 
 $$ = mm_strdup("sequences");
}
|  SERIALIZABLE
 { 
 $$ = mm_strdup("serializable");
}
|  SERVER
 { 
 $$ = mm_strdup("server");
}
|  SESSION
 { 
 $$ = mm_strdup("session");
}
|  SESSION_USER
 { 
 $$ = mm_strdup("session_user");
}
|  SET
 { 
 $$ = mm_strdup("set");
}
|  SETOF
 { 
 $$ = mm_strdup("setof");
}
|  SETS
 { 
 $$ = mm_strdup("sets");
}
|  SHARE
 { 
 $$ = mm_strdup("share");
}
|  SHOW
 { 
 $$ = mm_strdup("show");
}
|  SIMILAR
 { 
 $$ = mm_strdup("similar");
}
|  SIMPLE
 { 
 $$ = mm_strdup("simple");
}
|  SKIP
 { 
 $$ = mm_strdup("skip");
}
|  SMALLINT
 { 
 $$ = mm_strdup("smallint");
}
|  SNAPSHOT
 { 
 $$ = mm_strdup("snapshot");
}
|  SOME
 { 
 $$ = mm_strdup("some");
}
|  SQL_P
 { 
 $$ = mm_strdup("sql");
}
|  STABLE
 { 
 $$ = mm_strdup("stable");
}
|  STANDALONE_P
 { 
 $$ = mm_strdup("standalone");
}
|  START
 { 
 $$ = mm_strdup("start");
}
|  STATEMENT
 { 
 $$ = mm_strdup("statement");
}
|  STATISTICS
 { 
 $$ = mm_strdup("statistics");
}
|  STDIN
 { 
 $$ = mm_strdup("stdin");
}
|  STDOUT
 { 
 $$ = mm_strdup("stdout");
}
|  STORAGE
 { 
 $$ = mm_strdup("storage");
}
|  STORED
 { 
 $$ = mm_strdup("stored");
}
|  STRICT_P
 { 
 $$ = mm_strdup("strict");
}
|  STRIP_P
 { 
 $$ = mm_strdup("strip");
}
|  SUBSCRIPTION
 { 
 $$ = mm_strdup("subscription");
}
|  SUBSTRING
 { 
 $$ = mm_strdup("substring");
}
|  SUPPORT
 { 
 $$ = mm_strdup("support");
}
|  SYMMETRIC
 { 
 $$ = mm_strdup("symmetric");
}
|  SYSID
 { 
 $$ = mm_strdup("sysid");
}
|  SYSTEM_P
 { 
 $$ = mm_strdup("system");
}
|  TABLE
 { 
 $$ = mm_strdup("table");
}
|  TABLES
 { 
 $$ = mm_strdup("tables");
}
|  TABLESAMPLE
 { 
 $$ = mm_strdup("tablesample");
}
|  TABLESPACE
 { 
 $$ = mm_strdup("tablespace");
}
|  TEMP
 { 
 $$ = mm_strdup("temp");
}
|  TEMPLATE
 { 
 $$ = mm_strdup("template");
}
|  TEMPORARY
 { 
 $$ = mm_strdup("temporary");
}
|  TEXT_P
 { 
 $$ = mm_strdup("text");
}
|  THEN
 { 
 $$ = mm_strdup("then");
}
|  TIES
 { 
 $$ = mm_strdup("ties");
}
|  TIME
 { 
 $$ = mm_strdup("time");
}
|  TIMESTAMP
 { 
 $$ = mm_strdup("timestamp");
}
|  TRAILING
 { 
 $$ = mm_strdup("trailing");
}
|  TRANSACTION
 { 
 $$ = mm_strdup("transaction");
}
|  TRANSFORM
 { 
 $$ = mm_strdup("transform");
}
|  TREAT
 { 
 $$ = mm_strdup("treat");
}
|  TRIGGER
 { 
 $$ = mm_strdup("trigger");
}
|  TRIM
 { 
 $$ = mm_strdup("trim");
}
|  TRUE_P
 { 
 $$ = mm_strdup("true");
}
|  TRUNCATE
 { 
 $$ = mm_strdup("truncate");
}
|  TRUSTED
 { 
 $$ = mm_strdup("trusted");
}
|  TYPE_P
 { 
 $$ = mm_strdup("type");
}
|  TYPES_P
 { 
 $$ = mm_strdup("types");
}
|  UESCAPE
 { 
 $$ = mm_strdup("uescape");
}
|  UNBOUNDED
 { 
 $$ = mm_strdup("unbounded");
}
|  UNCOMMITTED
 { 
 $$ = mm_strdup("uncommitted");
}
|  UNENCRYPTED
 { 
 $$ = mm_strdup("unencrypted");
}
|  UNIQUE
 { 
 $$ = mm_strdup("unique");
}
|  UNKNOWN
 { 
 $$ = mm_strdup("unknown");
}
|  UNLISTEN
 { 
 $$ = mm_strdup("unlisten");
}
|  UNLOGGED
 { 
 $$ = mm_strdup("unlogged");
}
|  UNTIL
 { 
 $$ = mm_strdup("until");
}
|  UPDATE
 { 
 $$ = mm_strdup("update");
}
|  USER
 { 
 $$ = mm_strdup("user");
}
|  USING
 { 
 $$ = mm_strdup("using");
}
|  VACUUM
 { 
 $$ = mm_strdup("vacuum");
}
|  VALID
 { 
 $$ = mm_strdup("valid");
}
|  VALIDATE
 { 
 $$ = mm_strdup("validate");
}
|  VALIDATOR
 { 
 $$ = mm_strdup("validator");
}
|  VALUE_P
 { 
 $$ = mm_strdup("value");
}
|  VALUES
 { 
 $$ = mm_strdup("values");
}
|  VARCHAR
 { 
 $$ = mm_strdup("varchar");
}
|  VARIADIC
 { 
 $$ = mm_strdup("variadic");
}
|  VERBOSE
 { 
 $$ = mm_strdup("verbose");
}
|  VERSION_P
 { 
 $$ = mm_strdup("version");
}
|  VIEW
 { 
 $$ = mm_strdup("view");
}
|  VIEWS
 { 
 $$ = mm_strdup("views");
}
|  VOLATILE
 { 
 $$ = mm_strdup("volatile");
}
|  WHEN
 { 
 $$ = mm_strdup("when");
}
|  WHITESPACE_P
 { 
 $$ = mm_strdup("whitespace");
}
|  WORK
 { 
 $$ = mm_strdup("work");
}
|  WRAPPER
 { 
 $$ = mm_strdup("wrapper");
}
|  WRITE
 { 
 $$ = mm_strdup("write");
}
|  XML_P
 { 
 $$ = mm_strdup("xml");
}
|  XMLATTRIBUTES
 { 
 $$ = mm_strdup("xmlattributes");
}
|  XMLCONCAT
 { 
 $$ = mm_strdup("xmlconcat");
}
|  XMLELEMENT
 { 
 $$ = mm_strdup("xmlelement");
}
|  XMLEXISTS
 { 
 $$ = mm_strdup("xmlexists");
}
|  XMLFOREST
 { 
 $$ = mm_strdup("xmlforest");
}
|  XMLNAMESPACES
 { 
 $$ = mm_strdup("xmlnamespaces");
}
|  XMLPARSE
 { 
 $$ = mm_strdup("xmlparse");
}
|  XMLPI
 { 
 $$ = mm_strdup("xmlpi");
}
|  XMLROOT
 { 
 $$ = mm_strdup("xmlroot");
}
|  XMLSERIALIZE
 { 
 $$ = mm_strdup("xmlserialize");
}
|  XMLTABLE
 { 
 $$ = mm_strdup("xmltable");
}
|  YES_P
 { 
 $$ = mm_strdup("yes");
}
|  ZONE
 { 
 $$ = mm_strdup("zone");
}
;


/* trailer */
/* src/interfaces/ecpg/preproc/ecpg.trailer */

statements: /*EMPTY*/
				| statements statement
		;

statement: ecpgstart at toplevel_stmt ';'
				{
					if (connection)
						free(connection);
					connection = NULL;
				}
				| ecpgstart toplevel_stmt ';'
				{
					if (connection)
						free(connection);
					connection = NULL;
				}
				| ecpgstart ECPGVarDeclaration
				{
					fprintf(base_yyout, "%s", $2);
					free($2);
					output_line_number();
				}
				| ECPGDeclaration
				| c_thing               { fprintf(base_yyout, "%s", $1); free($1); }
				| CPP_LINE              { fprintf(base_yyout, "%s", $1); free($1); }
				| '{'                   { braces_open++; fputs("{", base_yyout); }
				| '}'
		{
			remove_typedefs(braces_open);
			remove_variables(braces_open--);
			if (braces_open == 0)
			{
				free(current_function);
				current_function = NULL;
			}
			fputs("}", base_yyout);
		}
		;

CreateAsStmt: CREATE OptTemp TABLE create_as_target AS {FoundInto = 0;} SelectStmt opt_with_data
		{
			if (FoundInto == 1)
				mmerror(PARSE_ERROR, ET_ERROR, "CREATE TABLE AS cannot specify INTO");

			$$ = cat_str(7, mm_strdup("create"), $2, mm_strdup("table"), $4, mm_strdup("as"), $7, $8);
		}
		|  CREATE OptTemp TABLE IF_P NOT EXISTS create_as_target AS {FoundInto = 0;} SelectStmt opt_with_data
		{
			if (FoundInto == 1)
				mmerror(PARSE_ERROR, ET_ERROR, "CREATE TABLE AS cannot specify INTO");

			$$ = cat_str(7, mm_strdup("create"), $2, mm_strdup("table if not exists"), $7, mm_strdup("as"), $10, $11);
		}
		;

at: AT connection_object
		{
			connection = $2;
			/*
			 * Do we have a variable as connection target?  Remove the variable
			 * from the variable list or else it will be used twice.
			 */
			if (argsinsert != NULL)
				argsinsert = NULL;
		}
		;

/*
 * the exec sql connect statement: connect to the given database
 */
ECPGConnect: SQL_CONNECT TO connection_target opt_connection_name opt_user
			{ $$ = cat_str(5, $3, mm_strdup(","), $5, mm_strdup(","), $4); }
		| SQL_CONNECT TO DEFAULT
			{ $$ = mm_strdup("NULL, NULL, NULL, \"DEFAULT\""); }
		  /* also allow ORACLE syntax */
		| SQL_CONNECT ora_user
			{ $$ = cat_str(3, mm_strdup("NULL,"), $2, mm_strdup(", NULL")); }
		| DATABASE connection_target
			{ $$ = cat2_str($2, mm_strdup(", NULL, NULL, NULL")); }
		;

connection_target: opt_database_name opt_server opt_port
		{
			/* old style: dbname[@server][:port] */
			if (strlen($2) > 0 && *($2) != '@')
				mmerror(PARSE_ERROR, ET_ERROR, "expected \"@\", found \"%s\"", $2);

			/* C strings need to be handled differently */
			if ($1[0] == '\"')
				$$ = $1;
			else
				$$ = make3_str(mm_strdup("\""), make3_str($1, $2, $3), mm_strdup("\""));
		}
		|  db_prefix ':' server opt_port '/' opt_database_name opt_options
		{
			/* new style: <tcp|unix>:postgresql://server[:port][/dbname] */
			if (strncmp($1, "unix:postgresql", strlen("unix:postgresql")) != 0 && strncmp($1, "tcp:postgresql", strlen("tcp:postgresql")) != 0)
				mmerror(PARSE_ERROR, ET_ERROR, "only protocols \"tcp\" and \"unix\" and database type \"postgresql\" are supported");

			if (strncmp($3, "//", strlen("//")) != 0)
				mmerror(PARSE_ERROR, ET_ERROR, "expected \"://\", found \"%s\"", $3);

			if (strncmp($1, "unix", strlen("unix")) == 0 &&
				strncmp($3 + strlen("//"), "localhost", strlen("localhost")) != 0 &&
				strncmp($3 + strlen("//"), "127.0.0.1", strlen("127.0.0.1")) != 0)
				mmerror(PARSE_ERROR, ET_ERROR, "Unix-domain sockets only work on \"localhost\" but not on \"%s\"", $3 + strlen("//"));

			$$ = make3_str(make3_str(mm_strdup("\""), $1, mm_strdup(":")), $3, make3_str(make3_str($4, mm_strdup("/"), $6), $7, mm_strdup("\"")));
		}
		| char_variable
		{
			$$ = $1;
		}
		| ecpg_sconst
		{
			/* We can only process double quoted strings not single quotes ones,
			 * so we change the quotes.
			 * Note, that the rule for ecpg_sconst adds these single quotes. */
			$1[0] = '\"';
			$1[strlen($1)-1] = '\"';
			$$ = $1;
		}
		;

opt_database_name: name				{ $$ = $1; }
		| /*EMPTY*/			{ $$ = EMPTY; }
		;

db_prefix: ecpg_ident cvariable
		{
			if (strcmp($2, "postgresql") != 0 && strcmp($2, "postgres") != 0)
				mmerror(PARSE_ERROR, ET_ERROR, "expected \"postgresql\", found \"%s\"", $2);

			if (strcmp($1, "tcp") != 0 && strcmp($1, "unix") != 0)
				mmerror(PARSE_ERROR, ET_ERROR, "invalid connection type: %s", $1);

			$$ = make3_str($1, mm_strdup(":"), $2);
		}
		;

server: Op server_name
		{
			if (strcmp($1, "@") != 0 && strcmp($1, "//") != 0)
				mmerror(PARSE_ERROR, ET_ERROR, "expected \"@\" or \"://\", found \"%s\"", $1);

			$$ = make2_str($1, $2);
		}
		;

opt_server: server			{ $$ = $1; }
		| /*EMPTY*/			{ $$ = EMPTY; }
		;

server_name: ColId					{ $$ = $1; }
		| ColId '.' server_name		{ $$ = make3_str($1, mm_strdup("."), $3); }
		| IP						{ $$ = make_name(); }
		;

opt_port: ':' Iconst		{ $$ = make2_str(mm_strdup(":"), $2); }
		| /*EMPTY*/	{ $$ = EMPTY; }
		;

opt_connection_name: AS connection_object	{ $$ = $2; }
		| /*EMPTY*/			{ $$ = mm_strdup("NULL"); }
		;

opt_user: USER ora_user		{ $$ = $2; }
		| /*EMPTY*/			{ $$ = mm_strdup("NULL, NULL"); }
		;

ora_user: user_name
			{ $$ = cat2_str($1, mm_strdup(", NULL")); }
		| user_name '/' user_name
			{ $$ = cat_str(3, $1, mm_strdup(","), $3); }
		| user_name SQL_IDENTIFIED BY user_name
			{ $$ = cat_str(3, $1, mm_strdup(","), $4); }
		| user_name USING user_name
			{ $$ = cat_str(3, $1, mm_strdup(","), $3); }
		;

user_name: RoleId
		{
			if ($1[0] == '\"')
				$$ = $1;
			else
				$$ = make3_str(mm_strdup("\""), $1, mm_strdup("\""));
		}
		| ecpg_sconst
		{
			if ($1[0] == '\"')
				$$ = $1;
			else
				$$ = make3_str(mm_strdup("\""), $1, mm_strdup("\""));
		}
		| civar
		{
			enum ECPGttype type = argsinsert->variable->type->type;

			/* if array see what's inside */
			if (type == ECPGt_array)
				type = argsinsert->variable->type->u.element->type;

			/* handle varchars */
			if (type == ECPGt_varchar)
				$$ = make2_str(mm_strdup(argsinsert->variable->name), mm_strdup(".arr"));
			else
				$$ = mm_strdup(argsinsert->variable->name);
		}
		;

char_variable: cvariable
		{
			/* check if we have a string variable */
			struct variable *p = find_variable($1);
			enum ECPGttype type = p->type->type;

			/* If we have just one character this is not a string */
			if (atol(p->type->size) == 1)
					mmerror(PARSE_ERROR, ET_ERROR, "invalid data type");
			else
			{
				/* if array see what's inside */
				if (type == ECPGt_array)
					type = p->type->u.element->type;

				switch (type)
				{
					case ECPGt_char:
					case ECPGt_unsigned_char:
					case ECPGt_string:
						$$ = $1;
						break;
					case ECPGt_varchar:
						$$ = make2_str($1, mm_strdup(".arr"));
						break;
					default:
						mmerror(PARSE_ERROR, ET_ERROR, "invalid data type");
						$$ = $1;
						break;
				}
			}
		}
		;

opt_options: Op connect_options
		{
			if (strlen($1) == 0)
				mmerror(PARSE_ERROR, ET_ERROR, "incomplete statement");

			if (strcmp($1, "?") != 0)
				mmerror(PARSE_ERROR, ET_ERROR, "unrecognized token \"%s\"", $1);

			$$ = make2_str(mm_strdup("?"), $2);
		}
		| /*EMPTY*/	{ $$ = EMPTY; }
		;

connect_options:  ColId opt_opt_value
			{
				$$ = make2_str($1, $2);
			}
		| ColId opt_opt_value Op connect_options
			{
				if (strlen($3) == 0)
					mmerror(PARSE_ERROR, ET_ERROR, "incomplete statement");

				if (strcmp($3, "&") != 0)
					mmerror(PARSE_ERROR, ET_ERROR, "unrecognized token \"%s\"", $3);

				$$ = cat_str(3, make2_str($1, $2), $3, $4);
			}
		;

opt_opt_value: /*EMPTY*/
			{ $$ = EMPTY; }
		| '=' Iconst
			{ $$ = make2_str(mm_strdup("="), $2); }
		| '=' ecpg_ident
			{ $$ = make2_str(mm_strdup("="), $2); }
		| '=' civar
			{ $$ = make2_str(mm_strdup("="), $2); }
		;

prepared_name: name
		{
			if ($1[0] == '\"' && $1[strlen($1)-1] == '\"') /* already quoted? */
				$$ = $1;
			else /* not quoted => convert to lowercase */
			{
				size_t i;

				for (i = 0; i< strlen($1); i++)
					$1[i] = tolower((unsigned char) $1[i]);

				$$ = make3_str(mm_strdup("\""), $1, mm_strdup("\""));
			}
		}
		| char_variable { $$ = $1; }
		;

/*
 * Declare Statement
 */
ECPGDeclareStmt: DECLARE prepared_name STATEMENT
		{
			struct declared_list *ptr = NULL;
			/* Check whether the declared name has been defined or not */
			for (ptr = g_declared_list; ptr != NULL; ptr = ptr->next)
			{
				if (strcmp($2, ptr->name) == 0)
				{
					/* re-definition is not allowed */
					mmerror(PARSE_ERROR, ET_ERROR, "name \"%s\" is already declared", ptr->name);
				}
			}

			/* Add a new declared name into the g_declared_list */
			ptr = NULL;
			ptr = (struct declared_list *)mm_alloc(sizeof(struct declared_list));
			if (ptr)
			{
				/* initial definition */
				ptr -> name = $2;
				if (connection)
					ptr -> connection = mm_strdup(connection);
				else
					ptr -> connection = NULL;

				ptr -> next = g_declared_list;
				g_declared_list = ptr;
			}

			$$ = cat_str(3 , mm_strdup("/* declare "), mm_strdup($2), mm_strdup(" as an SQL identifier */"));
		}
;

/*
 * Declare a prepared cursor. The syntax is different from the standard
 * declare statement, so we create a new rule.
 */
ECPGCursorStmt:  DECLARE cursor_name cursor_options CURSOR opt_hold FOR prepared_name
		{
			struct cursor *ptr, *this;
			char *cursor_marker = $2[0] == ':' ? mm_strdup("$0") : mm_strdup($2);
			int (* strcmp_fn)(const char *, const char *) = (($2[0] == ':' || $2[0] == '"') ? strcmp : pg_strcasecmp);
			struct variable *thisquery = (struct variable *)mm_alloc(sizeof(struct variable));
			char *comment;
			char *con;

			if (INFORMIX_MODE && pg_strcasecmp($2, "database") == 0)
                                mmfatal(PARSE_ERROR, "\"database\" cannot be used as cursor name in INFORMIX mode");

                        check_declared_list($7);
			con = connection ? connection : "NULL";
			for (ptr = cur; ptr != NULL; ptr = ptr->next)
			{
				if (strcmp_fn($2, ptr->name) == 0)
				{
					/* re-definition is a bug */
					if ($2[0] == ':')
						mmerror(PARSE_ERROR, ET_ERROR, "using variable \"%s\" in different declare statements is not supported", $2+1);
					else
						mmerror(PARSE_ERROR, ET_ERROR, "cursor \"%s\" is already defined", $2);
				}
			}

			this = (struct cursor *) mm_alloc(sizeof(struct cursor));

			/* initial definition */
			this->next = cur;
			this->name = $2;
			this->function = (current_function ? mm_strdup(current_function) : NULL);
			this->connection = connection ? mm_strdup(connection) : NULL;
			this->command =  cat_str(6, mm_strdup("declare"), cursor_marker, $3, mm_strdup("cursor"), $5, mm_strdup("for $1"));
			this->argsresult = NULL;
			this->argsresult_oos = NULL;

			thisquery->type = &ecpg_query;
			thisquery->brace_level = 0;
			thisquery->next = NULL;
			thisquery->name = (char *) mm_alloc(sizeof("ECPGprepared_statement(, , __LINE__)") + strlen(con) + strlen($7));
			sprintf(thisquery->name, "ECPGprepared_statement(%s, %s, __LINE__)", con, $7);

			this->argsinsert = NULL;
			this->argsinsert_oos = NULL;
			if ($2[0] == ':')
			{
				struct variable *var = find_variable($2 + 1);
				remove_variable_from_list(&argsinsert, var);
				add_variable_to_head(&(this->argsinsert), var, &no_indicator);
			}
			add_variable_to_head(&(this->argsinsert), thisquery, &no_indicator);

			cur = this;

			comment = cat_str(3, mm_strdup("/*"), mm_strdup(this->command), mm_strdup("*/"));

			$$ = cat_str(2, adjust_outofscope_cursor_vars(this),
					comment);
		}
		;

ECPGExecuteImmediateStmt: EXECUTE IMMEDIATE execstring
			{
			  /* execute immediate means prepare the statement and
			   * immediately execute it */
			  $$ = $3;
			};
/*
 * variable declaration outside exec sql declare block
 */
ECPGVarDeclaration: single_vt_declaration;

single_vt_declaration: type_declaration		{ $$ = $1; }
		| var_declaration		{ $$ = $1; }
		;

precision:	NumericOnly	{ $$ = $1; };

opt_scale:	',' NumericOnly	{ $$ = $2; }
		| /* EMPTY */	{ $$ = EMPTY; }
		;

ecpg_interval:	opt_interval	{ $$ = $1; }
		| YEAR_P TO MINUTE_P	{ $$ = mm_strdup("year to minute"); }
		| YEAR_P TO SECOND_P	{ $$ = mm_strdup("year to second"); }
		| DAY_P TO DAY_P		{ $$ = mm_strdup("day to day"); }
		| MONTH_P TO MONTH_P	{ $$ = mm_strdup("month to month"); }
		;

/*
 * variable declaration inside exec sql declare block
 */
ECPGDeclaration: sql_startdeclare
		{ fputs("/* exec sql begin declare section */", base_yyout); }
		var_type_declarations sql_enddeclare
		{
			fprintf(base_yyout, "%s/* exec sql end declare section */", $3);
			free($3);
			output_line_number();
		}
		;

sql_startdeclare: ecpgstart BEGIN_P DECLARE SQL_SECTION ';' {};

sql_enddeclare: ecpgstart END_P DECLARE SQL_SECTION ';' {};

var_type_declarations:	/*EMPTY*/			{ $$ = EMPTY; }
		| vt_declarations			{ $$ = $1; }
		;

vt_declarations:  single_vt_declaration			{ $$ = $1; }
		| CPP_LINE				{ $$ = $1; }
		| vt_declarations single_vt_declaration	{ $$ = cat2_str($1, $2); }
		| vt_declarations CPP_LINE		{ $$ = cat2_str($1, $2); }
		;

variable_declarations:	var_declaration	{ $$ = $1; }
		| variable_declarations var_declaration	{ $$ = cat2_str($1, $2); }
		;

type_declaration: S_TYPEDEF
	{
		/* reset this variable so we see if there was */
		/* an initializer specified */
		initializer = 0;
	}
	var_type opt_pointer ECPGColLabelCommon opt_array_bounds ';'
	{
		add_typedef($5, $6.index1, $6.index2, $3.type_enum, $3.type_dimension, $3.type_index, initializer, *$4 ? 1 : 0);

		fprintf(base_yyout, "typedef %s %s %s %s;\n", $3.type_str, *$4 ? "*" : "", $5, $6.str);
		output_line_number();
		$$ = mm_strdup("");
	};

var_declaration:
		storage_declaration var_type
		{
			actual_type[struct_level].type_storage = $1;
			actual_type[struct_level].type_enum = $2.type_enum;
			actual_type[struct_level].type_str = $2.type_str;
			actual_type[struct_level].type_dimension = $2.type_dimension;
			actual_type[struct_level].type_index = $2.type_index;
			actual_type[struct_level].type_sizeof = $2.type_sizeof;

			actual_startline[struct_level] = hashline_number();
		}
		variable_list ';'
		{
			$$ = cat_str(5, actual_startline[struct_level], $1, $2.type_str, $4, mm_strdup(";\n"));
		}
		| var_type
		{
			actual_type[struct_level].type_storage = EMPTY;
			actual_type[struct_level].type_enum = $1.type_enum;
			actual_type[struct_level].type_str = $1.type_str;
			actual_type[struct_level].type_dimension = $1.type_dimension;
			actual_type[struct_level].type_index = $1.type_index;
			actual_type[struct_level].type_sizeof = $1.type_sizeof;

			actual_startline[struct_level] = hashline_number();
		}
		variable_list ';'
		{
			$$ = cat_str(4, actual_startline[struct_level], $1.type_str, $3, mm_strdup(";\n"));
		}
		| struct_union_type_with_symbol ';'
		{
			$$ = cat2_str($1, mm_strdup(";"));
		}
		;

opt_bit_field:	':' Iconst	{ $$ =cat2_str(mm_strdup(":"), $2); }
		| /* EMPTY */	{ $$ = EMPTY; }
		;

storage_declaration: storage_clause storage_modifier
			{$$ = cat2_str ($1, $2); }
		| storage_clause		{$$ = $1; }
		| storage_modifier		{$$ = $1; }
		;

storage_clause : S_EXTERN	{ $$ = mm_strdup("extern"); }
		| S_STATIC			{ $$ = mm_strdup("static"); }
		| S_REGISTER		{ $$ = mm_strdup("register"); }
		| S_AUTO			{ $$ = mm_strdup("auto"); }
		;

storage_modifier : S_CONST	{ $$ = mm_strdup("const"); }
		| S_VOLATILE		{ $$ = mm_strdup("volatile"); }
		;

var_type:	simple_type
		{
			$$.type_enum = $1;
			$$.type_str = mm_strdup(ecpg_type_name($1));
			$$.type_dimension = mm_strdup("-1");
			$$.type_index = mm_strdup("-1");
			$$.type_sizeof = NULL;
		}
		| struct_union_type
		{
			$$.type_str = $1;
			$$.type_dimension = mm_strdup("-1");
			$$.type_index = mm_strdup("-1");

			if (strncmp($1, "struct", sizeof("struct")-1) == 0)
			{
				$$.type_enum = ECPGt_struct;
				$$.type_sizeof = ECPGstruct_sizeof;
			}
			else
			{
				$$.type_enum = ECPGt_union;
				$$.type_sizeof = NULL;
			}
		}
		| enum_type
		{
			$$.type_str = $1;
			$$.type_enum = ECPGt_int;
			$$.type_dimension = mm_strdup("-1");
			$$.type_index = mm_strdup("-1");
			$$.type_sizeof = NULL;
		}
		| ECPGColLabelCommon '(' precision opt_scale ')'
		{
			if (strcmp($1, "numeric") == 0)
			{
				$$.type_enum = ECPGt_numeric;
				$$.type_str = mm_strdup("numeric");
			}
			else if (strcmp($1, "decimal") == 0)
			{
				$$.type_enum = ECPGt_decimal;
				$$.type_str = mm_strdup("decimal");
			}
			else
			{
				mmerror(PARSE_ERROR, ET_ERROR, "only data types numeric and decimal have precision/scale argument");
				$$.type_enum = ECPGt_numeric;
				$$.type_str = mm_strdup("numeric");
			}

			$$.type_dimension = mm_strdup("-1");
			$$.type_index = mm_strdup("-1");
			$$.type_sizeof = NULL;
		}
		| ECPGColLabelCommon ecpg_interval
		{
			if (strlen($2) != 0 && strcmp ($1, "datetime") != 0 && strcmp ($1, "interval") != 0)
				mmerror (PARSE_ERROR, ET_ERROR, "interval specification not allowed here");

			/*
			 * Check for type names that the SQL grammar treats as
			 * unreserved keywords
			 */
			if (strcmp($1, "varchar") == 0)
			{
				$$.type_enum = ECPGt_varchar;
				$$.type_str = EMPTY; /*mm_strdup("varchar");*/
				$$.type_dimension = mm_strdup("-1");
				$$.type_index = mm_strdup("-1");
				$$.type_sizeof = NULL;
			}
			else if (strcmp($1, "bytea") == 0)
			{
				$$.type_enum = ECPGt_bytea;
				$$.type_str = EMPTY;
				$$.type_dimension = mm_strdup("-1");
				$$.type_index = mm_strdup("-1");
				$$.type_sizeof = NULL;
			}
			else if (strcmp($1, "float") == 0)
			{
				$$.type_enum = ECPGt_float;
				$$.type_str = mm_strdup("float");
				$$.type_dimension = mm_strdup("-1");
				$$.type_index = mm_strdup("-1");
				$$.type_sizeof = NULL;
			}
			else if (strcmp($1, "double") == 0)
			{
				$$.type_enum = ECPGt_double;
				$$.type_str = mm_strdup("double");
				$$.type_dimension = mm_strdup("-1");
				$$.type_index = mm_strdup("-1");
				$$.type_sizeof = NULL;
			}
			else if (strcmp($1, "numeric") == 0)
			{
				$$.type_enum = ECPGt_numeric;
				$$.type_str = mm_strdup("numeric");
				$$.type_dimension = mm_strdup("-1");
				$$.type_index = mm_strdup("-1");
				$$.type_sizeof = NULL;
			}
			else if (strcmp($1, "decimal") == 0)
			{
				$$.type_enum = ECPGt_decimal;
				$$.type_str = mm_strdup("decimal");
				$$.type_dimension = mm_strdup("-1");
				$$.type_index = mm_strdup("-1");
				$$.type_sizeof = NULL;
			}
			else if (strcmp($1, "date") == 0)
			{
				$$.type_enum = ECPGt_date;
				$$.type_str = mm_strdup("date");
				$$.type_dimension = mm_strdup("-1");
				$$.type_index = mm_strdup("-1");
				$$.type_sizeof = NULL;
			}
			else if (strcmp($1, "timestamp") == 0)
			{
				$$.type_enum = ECPGt_timestamp;
				$$.type_str = mm_strdup("timestamp");
				$$.type_dimension = mm_strdup("-1");
				$$.type_index = mm_strdup("-1");
				$$.type_sizeof = NULL;
			}
			else if (strcmp($1, "interval") == 0)
			{
				$$.type_enum = ECPGt_interval;
				$$.type_str = mm_strdup("interval");
				$$.type_dimension = mm_strdup("-1");
				$$.type_index = mm_strdup("-1");
				$$.type_sizeof = NULL;
			}
			else if (strcmp($1, "datetime") == 0)
			{
				$$.type_enum = ECPGt_timestamp;
				$$.type_str = mm_strdup("timestamp");
				$$.type_dimension = mm_strdup("-1");
				$$.type_index = mm_strdup("-1");
				$$.type_sizeof = NULL;
			}
			else if ((strcmp($1, "string") == 0) && INFORMIX_MODE)
			{
				$$.type_enum = ECPGt_string;
				$$.type_str = mm_strdup("char");
				$$.type_dimension = mm_strdup("-1");
				$$.type_index = mm_strdup("-1");
				$$.type_sizeof = NULL;
			}
			else
			{
				/* this is for typedef'ed types */
				struct typedefs *this = get_typedef($1);

				$$.type_str = (this->type->type_enum == ECPGt_varchar || this->type->type_enum == ECPGt_bytea) ? EMPTY : mm_strdup(this->name);
				$$.type_enum = this->type->type_enum;
				$$.type_dimension = this->type->type_dimension;
				$$.type_index = this->type->type_index;
				if (this->type->type_sizeof && strlen(this->type->type_sizeof) != 0)
					$$.type_sizeof = this->type->type_sizeof;
				else
					$$.type_sizeof = cat_str(3, mm_strdup("sizeof("), mm_strdup(this->name), mm_strdup(")"));

				struct_member_list[struct_level] = ECPGstruct_member_dup(this->struct_member_list);
			}
		}
		| s_struct_union_symbol
		{
			/* this is for named structs/unions */
			char *name;
			struct typedefs *this;
			bool forward = (forward_name != NULL && strcmp($1.symbol, forward_name) == 0 && strcmp($1.su, "struct") == 0);

			name = cat2_str($1.su, $1.symbol);
			/* Do we have a forward definition? */
			if (!forward)
			{
				/* No */

				this = get_typedef(name);
				$$.type_str = mm_strdup(this->name);
				$$.type_enum = this->type->type_enum;
				$$.type_dimension = this->type->type_dimension;
				$$.type_index = this->type->type_index;
				$$.type_sizeof = this->type->type_sizeof;
				struct_member_list[struct_level] = ECPGstruct_member_dup(this->struct_member_list);
				free(name);
			}
			else
			{
				$$.type_str = name;
				$$.type_enum = ECPGt_long;
				$$.type_dimension = mm_strdup("-1");
				$$.type_index = mm_strdup("-1");
				$$.type_sizeof = mm_strdup("");
				struct_member_list[struct_level] = NULL;
			}
		}
		;

enum_type: ENUM_P symbol enum_definition
			{ $$ = cat_str(3, mm_strdup("enum"), $2, $3); }
		| ENUM_P enum_definition
			{ $$ = cat2_str(mm_strdup("enum"), $2); }
		| ENUM_P symbol
			{ $$ = cat2_str(mm_strdup("enum"), $2); }
		;

enum_definition: '{' c_list '}'
			{ $$ = cat_str(3, mm_strdup("{"), $2, mm_strdup("}")); };

struct_union_type_with_symbol: s_struct_union_symbol
		{
			struct_member_list[struct_level++] = NULL;
			if (struct_level >= STRUCT_DEPTH)
				 mmerror(PARSE_ERROR, ET_ERROR, "too many levels in nested structure/union definition");
			forward_name = mm_strdup($1.symbol);
		}
		'{' variable_declarations '}'
		{
			struct typedefs *ptr, *this;
			struct this_type su_type;

			ECPGfree_struct_member(struct_member_list[struct_level]);
			struct_member_list[struct_level] = NULL;
			struct_level--;
			if (strncmp($1.su, "struct", sizeof("struct")-1) == 0)
				su_type.type_enum = ECPGt_struct;
			else
				su_type.type_enum = ECPGt_union;
			su_type.type_str = cat2_str($1.su, $1.symbol);
			free(forward_name);
			forward_name = NULL;

			/* This is essentially a typedef but needs the keyword struct/union as well.
			 * So we create the typedef for each struct definition with symbol */
			for (ptr = types; ptr != NULL; ptr = ptr->next)
			{
					if (strcmp(su_type.type_str, ptr->name) == 0)
							/* re-definition is a bug */
							mmerror(PARSE_ERROR, ET_ERROR, "type \"%s\" is already defined", su_type.type_str);
			}

			this = (struct typedefs *) mm_alloc(sizeof(struct typedefs));

			/* initial definition */
			this->next = types;
			this->name = mm_strdup(su_type.type_str);
			this->brace_level = braces_open;
			this->type = (struct this_type *) mm_alloc(sizeof(struct this_type));
			this->type->type_enum = su_type.type_enum;
			this->type->type_str = mm_strdup(su_type.type_str);
			this->type->type_dimension = mm_strdup("-1"); /* dimension of array */
			this->type->type_index = mm_strdup("-1");	/* length of string */
			this->type->type_sizeof = ECPGstruct_sizeof;
			this->struct_member_list = struct_member_list[struct_level];

			types = this;
			$$ = cat_str(4, su_type.type_str, mm_strdup("{"), $4, mm_strdup("}"));
		}
		;

struct_union_type: struct_union_type_with_symbol	{ $$ = $1; }
		| s_struct_union
		{
			struct_member_list[struct_level++] = NULL;
			if (struct_level >= STRUCT_DEPTH)
				 mmerror(PARSE_ERROR, ET_ERROR, "too many levels in nested structure/union definition");
		}
		'{' variable_declarations '}'
		{
			ECPGfree_struct_member(struct_member_list[struct_level]);
			struct_member_list[struct_level] = NULL;
			struct_level--;
			$$ = cat_str(4, $1, mm_strdup("{"), $4, mm_strdup("}"));
		}
		;

s_struct_union_symbol: SQL_STRUCT symbol
		{
			$$.su = mm_strdup("struct");
			$$.symbol = $2;
			ECPGstruct_sizeof = cat_str(3, mm_strdup("sizeof("), cat2_str(mm_strdup($$.su), mm_strdup($$.symbol)), mm_strdup(")"));
		}
		| UNION symbol
		{
			$$.su = mm_strdup("union");
			$$.symbol = $2;
		}
		;

s_struct_union: SQL_STRUCT
		{
			ECPGstruct_sizeof = mm_strdup(""); /* This must not be NULL to distinguish from simple types. */
			$$ = mm_strdup("struct");
		}
		| UNION
		{
			$$ = mm_strdup("union");
		}
		;

simple_type: unsigned_type					{ $$=$1; }
		|	opt_signed signed_type			{ $$=$2; }
		;

unsigned_type: SQL_UNSIGNED SQL_SHORT		{ $$ = ECPGt_unsigned_short; }
		| SQL_UNSIGNED SQL_SHORT INT_P	{ $$ = ECPGt_unsigned_short; }
		| SQL_UNSIGNED						{ $$ = ECPGt_unsigned_int; }
		| SQL_UNSIGNED INT_P				{ $$ = ECPGt_unsigned_int; }
		| SQL_UNSIGNED SQL_LONG				{ $$ = ECPGt_unsigned_long; }
		| SQL_UNSIGNED SQL_LONG INT_P		{ $$ = ECPGt_unsigned_long; }
		| SQL_UNSIGNED SQL_LONG SQL_LONG	{ $$ = ECPGt_unsigned_long_long; }
		| SQL_UNSIGNED SQL_LONG SQL_LONG INT_P { $$ = ECPGt_unsigned_long_long; }
		| SQL_UNSIGNED CHAR_P			{ $$ = ECPGt_unsigned_char; }
		;

signed_type: SQL_SHORT				{ $$ = ECPGt_short; }
		| SQL_SHORT INT_P			{ $$ = ECPGt_short; }
		| INT_P						{ $$ = ECPGt_int; }
		| SQL_LONG					{ $$ = ECPGt_long; }
		| SQL_LONG INT_P			{ $$ = ECPGt_long; }
		| SQL_LONG SQL_LONG			{ $$ = ECPGt_long_long; }
		| SQL_LONG SQL_LONG INT_P	{ $$ = ECPGt_long_long; }
		| SQL_BOOL					{ $$ = ECPGt_bool; }
		| CHAR_P					{ $$ = ECPGt_char; }
		| DOUBLE_P					{ $$ = ECPGt_double; }
		;

opt_signed: SQL_SIGNED
		|	/* EMPTY */
		;

variable_list: variable
			{ $$ = $1; }
		| variable_list ',' variable
		{
			if (actual_type[struct_level].type_enum == ECPGt_varchar || actual_type[struct_level].type_enum == ECPGt_bytea)
				$$ = cat_str(4, $1, mm_strdup(";"), mm_strdup(actual_type[struct_level].type_storage), $3);
			else
				$$ = cat_str(3, $1, mm_strdup(","), $3);
		}
		;

variable: opt_pointer ECPGColLabel opt_array_bounds opt_bit_field opt_initializer
		{
			struct ECPGtype * type;
			char *dimension = $3.index1;	/* dimension of array */
			char *length = $3.index2;		/* length of string */
			char *dim_str;
			char *vcn;
			int *varlen_type_counter;
			char *struct_name;

			adjust_array(actual_type[struct_level].type_enum, &dimension, &length, actual_type[struct_level].type_dimension, actual_type[struct_level].type_index, strlen($1), false);
			switch (actual_type[struct_level].type_enum)
			{
				case ECPGt_struct:
				case ECPGt_union:
					if (atoi(dimension) < 0)
						type = ECPGmake_struct_type(struct_member_list[struct_level], actual_type[struct_level].type_enum, actual_type[struct_level].type_str, actual_type[struct_level].type_sizeof);
					else
						type = ECPGmake_array_type(ECPGmake_struct_type(struct_member_list[struct_level], actual_type[struct_level].type_enum, actual_type[struct_level].type_str, actual_type[struct_level].type_sizeof), dimension);

					$$ = cat_str(5, $1, mm_strdup($2), $3.str, $4, $5);
					break;

				case ECPGt_varchar:
				case ECPGt_bytea:
					if (actual_type[struct_level].type_enum == ECPGt_varchar)
					{
						varlen_type_counter = &varchar_counter;
						struct_name = " struct varchar_";
					}
					else
					{
						varlen_type_counter = &bytea_counter;
						struct_name = " struct bytea_";
					}
					if (atoi(dimension) < 0)
						type = ECPGmake_simple_type(actual_type[struct_level].type_enum, length, *varlen_type_counter);
					else
						type = ECPGmake_array_type(ECPGmake_simple_type(actual_type[struct_level].type_enum, length, *varlen_type_counter), dimension);

					if (strcmp(dimension, "0") == 0 || abs(atoi(dimension)) == 1)
							dim_str=mm_strdup("");
					else
							dim_str=cat_str(3, mm_strdup("["), mm_strdup(dimension), mm_strdup("]"));
					/* cannot check for atoi <= 0 because a defined constant will yield 0 here as well */
					if (atoi(length) < 0 || strcmp(length, "0") == 0)
						mmerror(PARSE_ERROR, ET_ERROR, "pointers to varchar are not implemented");

					/* make sure varchar struct name is unique by adding a unique counter to its definition */
					vcn = (char *) mm_alloc(sizeof(int) * CHAR_BIT * 10 / 3);
					sprintf(vcn, "%d", *varlen_type_counter);
					if (strcmp(dimension, "0") == 0)
						$$ = cat_str(7, make2_str(mm_strdup(struct_name), vcn), mm_strdup(" { int len; char arr["), mm_strdup(length), mm_strdup("]; } *"), mm_strdup($2), $4, $5);
					else
						$$ = cat_str(8, make2_str(mm_strdup(struct_name), vcn), mm_strdup(" { int len; char arr["), mm_strdup(length), mm_strdup("]; } "), mm_strdup($2), dim_str, $4, $5);
					(*varlen_type_counter)++;
					break;

				case ECPGt_char:
				case ECPGt_unsigned_char:
				case ECPGt_string:
					if (atoi(dimension) == -1)
					{
						int i = strlen($5);

						if (atoi(length) == -1 && i > 0) /* char <var>[] = "string" */
						{
							/* if we have an initializer but no string size set, let's use the initializer's length */
							free(length);
							length = mm_alloc(i+sizeof("sizeof()"));
							sprintf(length, "sizeof(%s)", $5+2);
						}
						type = ECPGmake_simple_type(actual_type[struct_level].type_enum, length, 0);
					}
					else
						type = ECPGmake_array_type(ECPGmake_simple_type(actual_type[struct_level].type_enum, length, 0), dimension);

					$$ = cat_str(5, $1, mm_strdup($2), $3.str, $4, $5);
					break;

				default:
					if (atoi(dimension) < 0)
						type = ECPGmake_simple_type(actual_type[struct_level].type_enum, mm_strdup("1"), 0);
					else
						type = ECPGmake_array_type(ECPGmake_simple_type(actual_type[struct_level].type_enum, mm_strdup("1"), 0), dimension);

					$$ = cat_str(5, $1, mm_strdup($2), $3.str, $4, $5);
					break;
			}

			if (struct_level == 0)
				new_variable($2, type, braces_open);
			else
				ECPGmake_struct_member($2, type, &(struct_member_list[struct_level - 1]));

			free($2);
		}
		;

opt_initializer: /*EMPTY*/
			{ $$ = EMPTY; }
		| '=' c_term
		{
			initializer = 1;
			$$ = cat2_str(mm_strdup("="), $2);
		}
		;

opt_pointer: /*EMPTY*/				{ $$ = EMPTY; }
		| '*'						{ $$ = mm_strdup("*"); }
		| '*' '*'					{ $$ = mm_strdup("**"); }
		;

/*
 * We try to simulate the correct DECLARE syntax here so we get dynamic SQL
 */
ECPGDeclare: DECLARE STATEMENT ecpg_ident
		{
			/* this is only supported for compatibility */
			$$ = cat_str(3, mm_strdup("/* declare statement"), $3, mm_strdup("*/"));
		}
		;
/*
 * the exec sql disconnect statement: disconnect from the given database
 */
ECPGDisconnect: SQL_DISCONNECT dis_name { $$ = $2; }
		;

dis_name: connection_object			{ $$ = $1; }
		| CURRENT_P			{ $$ = mm_strdup("\"CURRENT\""); }
		| ALL				{ $$ = mm_strdup("\"ALL\""); }
		| /* EMPTY */			{ $$ = mm_strdup("\"CURRENT\""); }
		;

connection_object: name				{ $$ = make3_str(mm_strdup("\""), $1, mm_strdup("\"")); }
		| DEFAULT			{ $$ = mm_strdup("\"DEFAULT\""); }
		| char_variable			{ $$ = $1; }
		;

execstring: char_variable
			{ $$ = $1; }
		|	CSTRING
			{ $$ = make3_str(mm_strdup("\""), $1, mm_strdup("\"")); }
		;

/*
 * the exec sql free command to deallocate a previously
 * prepared statement
 */
ECPGFree:	SQL_FREE cursor_name	{ $$ = $2; }
		| SQL_FREE ALL	{ $$ = mm_strdup("all"); }
		;

/*
 * open is an open cursor, at the moment this has to be removed
 */
ECPGOpen: SQL_OPEN cursor_name opt_ecpg_using
		{
			if ($2[0] == ':')
				remove_variable_from_list(&argsinsert, find_variable($2 + 1));
			$$ = $2;
		}
		;

opt_ecpg_using: /*EMPTY*/	{ $$ = EMPTY; }
		| ecpg_using		{ $$ = $1; }
		;

ecpg_using:	USING using_list	{ $$ = EMPTY; }
		| using_descriptor		{ $$ = $1; }
		;

using_descriptor: USING SQL_P SQL_DESCRIPTOR quoted_ident_stringvar
		{
			add_variable_to_head(&argsinsert, descriptor_variable($4,0), &no_indicator);
			$$ = EMPTY;
		}
		| USING SQL_DESCRIPTOR name
		{
			add_variable_to_head(&argsinsert, sqlda_variable($3), &no_indicator);
			$$ = EMPTY;
		}
		;

into_descriptor: INTO SQL_P SQL_DESCRIPTOR quoted_ident_stringvar
		{
			add_variable_to_head(&argsresult, descriptor_variable($4,1), &no_indicator);
			$$ = EMPTY;
		}
		| INTO SQL_DESCRIPTOR name
		{
			add_variable_to_head(&argsresult, sqlda_variable($3), &no_indicator);
			$$ = EMPTY;
		}
		;

into_sqlda: INTO name
		{
			add_variable_to_head(&argsresult, sqlda_variable($2), &no_indicator);
			$$ = EMPTY;
		}
		;

using_list: UsingValue | UsingValue ',' using_list;

UsingValue: UsingConst
		{
			char *length = mm_alloc(32);

			sprintf(length, "%zu", strlen($1));
			add_variable_to_head(&argsinsert, new_variable($1, ECPGmake_simple_type(ECPGt_const, length, 0), 0), &no_indicator);
		}
		| civar { $$ = EMPTY; }
		| civarind { $$ = EMPTY; }
		;

UsingConst: Iconst			{ $$ = $1; }
		| '+' Iconst		{ $$ = cat_str(2, mm_strdup("+"), $2); }
		| '-' Iconst		{ $$ = cat_str(2, mm_strdup("-"), $2); }
		| ecpg_fconst		{ $$ = $1; }
		| '+' ecpg_fconst	{ $$ = cat_str(2, mm_strdup("+"), $2); }
		| '-' ecpg_fconst	{ $$ = cat_str(2, mm_strdup("-"), $2); }
		| ecpg_sconst		{ $$ = $1; }
		| ecpg_bconst		{ $$ = $1; }
		| ecpg_xconst		{ $$ = $1; }
		;

/*
 * We accept DESCRIBE [OUTPUT] but do nothing with DESCRIBE INPUT so far.
 */
ECPGDescribe: SQL_DESCRIBE INPUT_P prepared_name using_descriptor
	{
		$$.input = 1;
		$$.stmt_name = $3;
	}
	| SQL_DESCRIBE opt_output prepared_name using_descriptor
	{
		struct variable *var;
		var = argsinsert->variable;
		remove_variable_from_list(&argsinsert, var);
		add_variable_to_head(&argsresult, var, &no_indicator);

		$$.input = 0;
		$$.stmt_name = $3;
	}
	| SQL_DESCRIBE opt_output prepared_name into_descriptor
	{
		$$.input = 0;
		$$.stmt_name = $3;
	}
	| SQL_DESCRIBE INPUT_P prepared_name into_sqlda
	{
		$$.input = 1;
		$$.stmt_name = $3;
	}
	| SQL_DESCRIBE opt_output prepared_name into_sqlda
	{
		$$.input = 0;
		$$.stmt_name = $3;
	}
	;

opt_output:	SQL_OUTPUT	{ $$ = mm_strdup("output"); }
	|	/* EMPTY */	{ $$ = EMPTY; }
	;

/*
 * dynamic SQL: descriptor based access
 *	originally written by Christof Petig <christof.petig@wtal.de>
 *			and Peter Eisentraut <peter.eisentraut@credativ.de>
 */

/*
 * allocate a descriptor
 */
ECPGAllocateDescr: SQL_ALLOCATE SQL_DESCRIPTOR quoted_ident_stringvar
		{
			add_descriptor($3,connection);
			$$ = $3;
		}
		;


/*
 * deallocate a descriptor
 */
ECPGDeallocateDescr:	DEALLOCATE SQL_DESCRIPTOR quoted_ident_stringvar
		{
			drop_descriptor($3,connection);
			$$ = $3;
		}
		;

/*
 * manipulate a descriptor header
 */

ECPGGetDescriptorHeader: SQL_GET SQL_DESCRIPTOR quoted_ident_stringvar ECPGGetDescHeaderItems
			{  $$ = $3; }
		;

ECPGGetDescHeaderItems: ECPGGetDescHeaderItem
		| ECPGGetDescHeaderItems ',' ECPGGetDescHeaderItem
		;

ECPGGetDescHeaderItem: cvariable '=' desc_header_item
			{ push_assignment($1, $3); }
		;


ECPGSetDescriptorHeader: SET SQL_DESCRIPTOR quoted_ident_stringvar ECPGSetDescHeaderItems
			{ $$ = $3; }
		;

ECPGSetDescHeaderItems: ECPGSetDescHeaderItem
		| ECPGSetDescHeaderItems ',' ECPGSetDescHeaderItem
		;

ECPGSetDescHeaderItem: desc_header_item '=' IntConstVar
		{
			push_assignment($3, $1);
		}
		;

IntConstVar: Iconst
		{
			char *length = mm_alloc(sizeof(int) * CHAR_BIT * 10 / 3);

			sprintf(length, "%zu", strlen($1));
			new_variable($1, ECPGmake_simple_type(ECPGt_const, length, 0), 0);
			$$ = $1;
		}
		| cvariable
		{
			$$ = $1;
		}
		;

desc_header_item:	SQL_COUNT			{ $$ = ECPGd_count; }
		;

/*
 * manipulate a descriptor
 */

ECPGGetDescriptor:	SQL_GET SQL_DESCRIPTOR quoted_ident_stringvar VALUE_P IntConstVar ECPGGetDescItems
			{  $$.str = $5; $$.name = $3; }
		;

ECPGGetDescItems: ECPGGetDescItem
		| ECPGGetDescItems ',' ECPGGetDescItem
		;

ECPGGetDescItem: cvariable '=' descriptor_item	{ push_assignment($1, $3); };


ECPGSetDescriptor:	SET SQL_DESCRIPTOR quoted_ident_stringvar VALUE_P IntConstVar ECPGSetDescItems
			{  $$.str = $5; $$.name = $3; }
		;

ECPGSetDescItems: ECPGSetDescItem
		| ECPGSetDescItems ',' ECPGSetDescItem
		;

ECPGSetDescItem: descriptor_item '=' AllConstVar
		{
			push_assignment($3, $1);
		}
		;

AllConstVar: ecpg_fconst
		{
			char *length = mm_alloc(sizeof(int) * CHAR_BIT * 10 / 3);

			sprintf(length, "%zu", strlen($1));
			new_variable($1, ECPGmake_simple_type(ECPGt_const, length, 0), 0);
			$$ = $1;
		}

		| IntConstVar
		{
			$$ = $1;
		}

		| '-' ecpg_fconst
		{
			char *length = mm_alloc(sizeof(int) * CHAR_BIT * 10 / 3);
			char *var = cat2_str(mm_strdup("-"), $2);

			sprintf(length, "%zu", strlen(var));
			new_variable(var, ECPGmake_simple_type(ECPGt_const, length, 0), 0);
			$$ = var;
		}

		| '-' Iconst
		{
			char *length = mm_alloc(sizeof(int) * CHAR_BIT * 10 / 3);
			char *var = cat2_str(mm_strdup("-"), $2);

			sprintf(length, "%zu", strlen(var));
			new_variable(var, ECPGmake_simple_type(ECPGt_const, length, 0), 0);
			$$ = var;
		}

		| ecpg_sconst
		{
			char *length = mm_alloc(sizeof(int) * CHAR_BIT * 10 / 3);
			char *var = $1 + 1;

			var[strlen(var) - 1] = '\0';
			sprintf(length, "%zu", strlen(var));
			new_variable(var, ECPGmake_simple_type(ECPGt_const, length, 0), 0);
			$$ = var;
		}
		;

descriptor_item:	SQL_CARDINALITY			{ $$ = ECPGd_cardinality; }
		| DATA_P				{ $$ = ECPGd_data; }
		| SQL_DATETIME_INTERVAL_CODE		{ $$ = ECPGd_di_code; }
		| SQL_DATETIME_INTERVAL_PRECISION	{ $$ = ECPGd_di_precision; }
		| SQL_INDICATOR				{ $$ = ECPGd_indicator; }
		| SQL_KEY_MEMBER			{ $$ = ECPGd_key_member; }
		| SQL_LENGTH				{ $$ = ECPGd_length; }
		| NAME_P				{ $$ = ECPGd_name; }
		| SQL_NULLABLE				{ $$ = ECPGd_nullable; }
		| SQL_OCTET_LENGTH			{ $$ = ECPGd_octet; }
		| PRECISION				{ $$ = ECPGd_precision; }
		| SQL_RETURNED_LENGTH			{ $$ = ECPGd_length; }
		| SQL_RETURNED_OCTET_LENGTH		{ $$ = ECPGd_ret_octet; }
		| SQL_SCALE				{ $$ = ECPGd_scale; }
		| TYPE_P				{ $$ = ECPGd_type; }
		;

/*
 * set/reset the automatic transaction mode, this needs a different handling
 * as the other set commands
 */
ECPGSetAutocommit:	SET SQL_AUTOCOMMIT '=' on_off	{ $$ = $4; }
		|  SET SQL_AUTOCOMMIT TO on_off   { $$ = $4; }
		;

on_off: ON				{ $$ = mm_strdup("on"); }
		| OFF			{ $$ = mm_strdup("off"); }
		;

/*
 * set the actual connection, this needs a different handling as the other
 * set commands
 */
ECPGSetConnection:	SET CONNECTION TO connection_object { $$ = $4; }
		| SET CONNECTION '=' connection_object { $$ = $4; }
		| SET CONNECTION  connection_object { $$ = $3; }
		;

/*
 * define a new type for embedded SQL
 */
ECPGTypedef: TYPE_P
		{
			/* reset this variable so we see if there was */
			/* an initializer specified */
			initializer = 0;
		}
		ECPGColLabelCommon IS var_type opt_array_bounds opt_reference
		{
			add_typedef($3, $6.index1, $6.index2, $5.type_enum, $5.type_dimension, $5.type_index, initializer, *$7 ? 1 : 0);

			if (auto_create_c == false)
				$$ = cat_str(7, mm_strdup("/* exec sql type"), mm_strdup($3), mm_strdup("is"), mm_strdup($5.type_str), mm_strdup($6.str), $7, mm_strdup("*/"));
			else
				$$ = cat_str(6, mm_strdup("typedef "), mm_strdup($5.type_str), *$7?mm_strdup("*"):mm_strdup(""), mm_strdup($3), mm_strdup($6.str), mm_strdup(";"));
		}
		;

opt_reference: SQL_REFERENCE		{ $$ = mm_strdup("reference"); }
		| /*EMPTY*/					{ $$ = EMPTY; }
		;

/*
 * define the type of one variable for embedded SQL
 */
ECPGVar: SQL_VAR
		{
			/* reset this variable so we see if there was */
			/* an initializer specified */
			initializer = 0;
		}
		ColLabel IS var_type opt_array_bounds opt_reference
		{
			struct variable *p = find_variable($3);
			char *dimension = $6.index1;
			char *length = $6.index2;
			struct ECPGtype * type;

			if (($5.type_enum == ECPGt_struct ||
				 $5.type_enum == ECPGt_union) &&
				initializer == 1)
				mmerror(PARSE_ERROR, ET_ERROR, "initializer not allowed in EXEC SQL VAR command");
			else
			{
				adjust_array($5.type_enum, &dimension, &length, $5.type_dimension, $5.type_index, *$7?1:0, false);

				switch ($5.type_enum)
				{
					case ECPGt_struct:
					case ECPGt_union:
						if (atoi(dimension) < 0)
							type = ECPGmake_struct_type(struct_member_list[struct_level], $5.type_enum, $5.type_str, $5.type_sizeof);
						else
							type = ECPGmake_array_type(ECPGmake_struct_type(struct_member_list[struct_level], $5.type_enum, $5.type_str, $5.type_sizeof), dimension);
						break;

					case ECPGt_varchar:
					case ECPGt_bytea:
						if (atoi(dimension) == -1)
							type = ECPGmake_simple_type($5.type_enum, length, 0);
						else
							type = ECPGmake_array_type(ECPGmake_simple_type($5.type_enum, length, 0), dimension);
						break;

					case ECPGt_char:
					case ECPGt_unsigned_char:
					case ECPGt_string:
						if (atoi(dimension) == -1)
							type = ECPGmake_simple_type($5.type_enum, length, 0);
						else
							type = ECPGmake_array_type(ECPGmake_simple_type($5.type_enum, length, 0), dimension);
						break;

					default:
						if (atoi(length) >= 0)
							mmerror(PARSE_ERROR, ET_ERROR, "multidimensional arrays for simple data types are not supported");

						if (atoi(dimension) < 0)
							type = ECPGmake_simple_type($5.type_enum, mm_strdup("1"), 0);
						else
							type = ECPGmake_array_type(ECPGmake_simple_type($5.type_enum, mm_strdup("1"), 0), dimension);
						break;
				}

				ECPGfree_type(p->type);
				p->type = type;
			}

			$$ = cat_str(7, mm_strdup("/* exec sql var"), mm_strdup($3), mm_strdup("is"), mm_strdup($5.type_str), mm_strdup($6.str), $7, mm_strdup("*/"));
		}
		;

/*
 * whenever statement: decide what to do in case of error/no data found
 * according to SQL standards we lack: SQLSTATE, CONSTRAINT and SQLEXCEPTION
 */
ECPGWhenever: SQL_WHENEVER SQL_SQLERROR action
		{
			when_error.code = $<action>3.code;
			when_error.command = $<action>3.command;
			$$ = cat_str(3, mm_strdup("/* exec sql whenever sqlerror "), $3.str, mm_strdup("; */"));
		}
		| SQL_WHENEVER NOT SQL_FOUND action
		{
			when_nf.code = $<action>4.code;
			when_nf.command = $<action>4.command;
			$$ = cat_str(3, mm_strdup("/* exec sql whenever not found "), $4.str, mm_strdup("; */"));
		}
		| SQL_WHENEVER SQL_SQLWARNING action
		{
			when_warn.code = $<action>3.code;
			when_warn.command = $<action>3.command;
			$$ = cat_str(3, mm_strdup("/* exec sql whenever sql_warning "), $3.str, mm_strdup("; */"));
		}
		;

action : CONTINUE_P
		{
			$<action>$.code = W_NOTHING;
			$<action>$.command = NULL;
			$<action>$.str = mm_strdup("continue");
		}
		| SQL_SQLPRINT
		{
			$<action>$.code = W_SQLPRINT;
			$<action>$.command = NULL;
			$<action>$.str = mm_strdup("sqlprint");
		}
		| SQL_STOP
		{
			$<action>$.code = W_STOP;
			$<action>$.command = NULL;
			$<action>$.str = mm_strdup("stop");
		}
		| SQL_GOTO name
		{
			$<action>$.code = W_GOTO;
			$<action>$.command = mm_strdup($2);
			$<action>$.str = cat2_str(mm_strdup("goto "), $2);
		}
		| SQL_GO TO name
		{
			$<action>$.code = W_GOTO;
			$<action>$.command = mm_strdup($3);
			$<action>$.str = cat2_str(mm_strdup("goto "), $3);
		}
		| DO name '(' c_args ')'
		{
			$<action>$.code = W_DO;
			$<action>$.command = cat_str(4, $2, mm_strdup("("), $4, mm_strdup(")"));
			$<action>$.str = cat2_str(mm_strdup("do"), mm_strdup($<action>$.command));
		}
		| DO SQL_BREAK
		{
			$<action>$.code = W_BREAK;
			$<action>$.command = NULL;
			$<action>$.str = mm_strdup("break");
		}
		| DO CONTINUE_P
		{
			$<action>$.code = W_CONTINUE;
			$<action>$.command = NULL;
			$<action>$.str = mm_strdup("continue");
		}
		| CALL name '(' c_args ')'
		{
			$<action>$.code = W_DO;
			$<action>$.command = cat_str(4, $2, mm_strdup("("), $4, mm_strdup(")"));
			$<action>$.str = cat2_str(mm_strdup("call"), mm_strdup($<action>$.command));
		}
		| CALL name
		{
			$<action>$.code = W_DO;
			$<action>$.command = cat2_str($2, mm_strdup("()"));
			$<action>$.str = cat2_str(mm_strdup("call"), mm_strdup($<action>$.command));
		}
		;

/* some other stuff for ecpg */

/* additional unreserved keywords */
ECPGKeywords: ECPGKeywords_vanames	{ $$ = $1; }
		| ECPGKeywords_rest	{ $$ = $1; }
		;

ECPGKeywords_vanames:  SQL_BREAK		{ $$ = mm_strdup("break"); }
		| SQL_CARDINALITY				{ $$ = mm_strdup("cardinality"); }
		| SQL_COUNT						{ $$ = mm_strdup("count"); }
		| SQL_DATETIME_INTERVAL_CODE	{ $$ = mm_strdup("datetime_interval_code"); }
		| SQL_DATETIME_INTERVAL_PRECISION	{ $$ = mm_strdup("datetime_interval_precision"); }
		| SQL_FOUND						{ $$ = mm_strdup("found"); }
		| SQL_GO						{ $$ = mm_strdup("go"); }
		| SQL_GOTO						{ $$ = mm_strdup("goto"); }
		| SQL_IDENTIFIED				{ $$ = mm_strdup("identified"); }
		| SQL_INDICATOR				{ $$ = mm_strdup("indicator"); }
		| SQL_KEY_MEMBER			{ $$ = mm_strdup("key_member"); }
		| SQL_LENGTH				{ $$ = mm_strdup("length"); }
		| SQL_NULLABLE				{ $$ = mm_strdup("nullable"); }
		| SQL_OCTET_LENGTH			{ $$ = mm_strdup("octet_length"); }
		| SQL_RETURNED_LENGTH		{ $$ = mm_strdup("returned_length"); }
		| SQL_RETURNED_OCTET_LENGTH	{ $$ = mm_strdup("returned_octet_length"); }
		| SQL_SCALE					{ $$ = mm_strdup("scale"); }
		| SQL_SECTION				{ $$ = mm_strdup("section"); }
		| SQL_SQLERROR				{ $$ = mm_strdup("sqlerror"); }
		| SQL_SQLPRINT				{ $$ = mm_strdup("sqlprint"); }
		| SQL_SQLWARNING			{ $$ = mm_strdup("sqlwarning"); }
		| SQL_STOP					{ $$ = mm_strdup("stop"); }
		;

ECPGKeywords_rest:  SQL_CONNECT		{ $$ = mm_strdup("connect"); }
		| SQL_DESCRIBE				{ $$ = mm_strdup("describe"); }
		| SQL_DISCONNECT			{ $$ = mm_strdup("disconnect"); }
		| SQL_OPEN					{ $$ = mm_strdup("open"); }
		| SQL_VAR					{ $$ = mm_strdup("var"); }
		| SQL_WHENEVER				{ $$ = mm_strdup("whenever"); }
		;

/* additional keywords that can be SQL type names (but not ECPGColLabels) */
ECPGTypeName:  SQL_BOOL				{ $$ = mm_strdup("bool"); }
		| SQL_LONG					{ $$ = mm_strdup("long"); }
		| SQL_OUTPUT				{ $$ = mm_strdup("output"); }
		| SQL_SHORT					{ $$ = mm_strdup("short"); }
		| SQL_STRUCT				{ $$ = mm_strdup("struct"); }
		| SQL_SIGNED				{ $$ = mm_strdup("signed"); }
		| SQL_UNSIGNED				{ $$ = mm_strdup("unsigned"); }
		;

symbol: ColLabel					{ $$ = $1; }
		;

ECPGColId: ecpg_ident				{ $$ = $1; }
		| unreserved_keyword		{ $$ = $1; }
		| col_name_keyword			{ $$ = $1; }
		| ECPGunreserved_interval	{ $$ = $1; }
		| ECPGKeywords				{ $$ = $1; }
		| ECPGCKeywords				{ $$ = $1; }
		| CHAR_P					{ $$ = mm_strdup("char"); }
		| VALUES					{ $$ = mm_strdup("values"); }
		;

/*
 * Name classification hierarchy.
 *
 * These productions should match those in the core grammar, except that
 * we use all_unreserved_keyword instead of unreserved_keyword, and
 * where possible include ECPG keywords as well as core keywords.
 */

/* Column identifier --- names that can be column, table, etc names.
 */
ColId:	ecpg_ident					{ $$ = $1; }
		| all_unreserved_keyword	{ $$ = $1; }
		| col_name_keyword			{ $$ = $1; }
		| ECPGKeywords				{ $$ = $1; }
		| ECPGCKeywords				{ $$ = $1; }
		| CHAR_P					{ $$ = mm_strdup("char"); }
		| VALUES					{ $$ = mm_strdup("values"); }
		;

/* Type/function identifier --- names that can be type or function names.
 */
type_function_name:	ecpg_ident		{ $$ = $1; }
		| all_unreserved_keyword	{ $$ = $1; }
		| type_func_name_keyword	{ $$ = $1; }
		| ECPGKeywords				{ $$ = $1; }
		| ECPGCKeywords				{ $$ = $1; }
		| ECPGTypeName				{ $$ = $1; }
		;

/* Column label --- allowed labels in "AS" clauses.
 * This presently includes *all* Postgres keywords.
 */
ColLabel:  ECPGColLabel				{ $$ = $1; }
		| ECPGTypeName				{ $$ = $1; }
		| CHAR_P					{ $$ = mm_strdup("char"); }
		| CURRENT_P					{ $$ = mm_strdup("current"); }
		| INPUT_P					{ $$ = mm_strdup("input"); }
		| INT_P						{ $$ = mm_strdup("int"); }
		| TO						{ $$ = mm_strdup("to"); }
		| UNION						{ $$ = mm_strdup("union"); }
		| VALUES					{ $$ = mm_strdup("values"); }
		| ECPGCKeywords				{ $$ = $1; }
		| ECPGunreserved_interval	{ $$ = $1; }
		;

ECPGColLabel:  ECPGColLabelCommon	{ $$ = $1; }
		| unreserved_keyword		{ $$ = $1; }
		| reserved_keyword			{ $$ = $1; }
		| ECPGKeywords_rest			{ $$ = $1; }
		| CONNECTION				{ $$ = mm_strdup("connection"); }
		;

ECPGColLabelCommon:  ecpg_ident		{ $$ = $1; }
		| col_name_keyword			{ $$ = $1; }
		| type_func_name_keyword	{ $$ = $1; }
		| ECPGKeywords_vanames		{ $$ = $1; }
		;

ECPGCKeywords: S_AUTO				{ $$ = mm_strdup("auto"); }
		| S_CONST					{ $$ = mm_strdup("const"); }
		| S_EXTERN					{ $$ = mm_strdup("extern"); }
		| S_REGISTER				{ $$ = mm_strdup("register"); }
		| S_STATIC					{ $$ = mm_strdup("static"); }
		| S_TYPEDEF					{ $$ = mm_strdup("typedef"); }
		| S_VOLATILE				{ $$ = mm_strdup("volatile"); }
		;

/* "Unreserved" keywords --- available for use as any kind of name.
 */

/*
 * The following symbols must be excluded from ECPGColLabel and directly
 * included into ColLabel to enable C variables to get names from ECPGColLabel:
 * DAY_P, HOUR_P, MINUTE_P, MONTH_P, SECOND_P, YEAR_P.
 *
 * We also have to exclude CONNECTION, CURRENT, and INPUT for various reasons.
 * CONNECTION can be added back in all_unreserved_keyword, but CURRENT and
 * INPUT are reserved for ecpg purposes.
 *
 * The mentioned exclusions are done by $replace_line settings in parse.pl.
 */
all_unreserved_keyword: unreserved_keyword	{ $$ = $1; }
		| ECPGunreserved_interval			{ $$ = $1; }
		| CONNECTION						{ $$ = mm_strdup("connection"); }
		;

ECPGunreserved_interval: DAY_P				{ $$ = mm_strdup("day"); }
		| HOUR_P							{ $$ = mm_strdup("hour"); }
		| MINUTE_P							{ $$ = mm_strdup("minute"); }
		| MONTH_P							{ $$ = mm_strdup("month"); }
		| SECOND_P							{ $$ = mm_strdup("second"); }
		| YEAR_P							{ $$ = mm_strdup("year"); }
		;


into_list : coutputvariable | into_list ',' coutputvariable
		;

ecpgstart: SQL_START	{
				reset_variables();
				pacounter = 1;
			}
		;

c_args: /*EMPTY*/		{ $$ = EMPTY; }
		| c_list		{ $$ = $1; }
		;

coutputvariable: cvariable indicator
			{ add_variable_to_head(&argsresult, find_variable($1), find_variable($2)); }
		| cvariable
			{ add_variable_to_head(&argsresult, find_variable($1), &no_indicator); }
		;


civarind: cvariable indicator
		{
			if (find_variable($2)->type->type == ECPGt_array)
				mmerror(PARSE_ERROR, ET_ERROR, "arrays of indicators are not allowed on input");

			add_variable_to_head(&argsinsert, find_variable($1), find_variable($2));
			$$ = create_questionmarks($1, false);
		}
		;

char_civar: char_variable
		{
			char *ptr = strstr($1, ".arr");

			if (ptr) /* varchar, we need the struct name here, not the struct element */
				*ptr = '\0';
			add_variable_to_head(&argsinsert, find_variable($1), &no_indicator);
			$$ = $1;
		}
		;

civar: cvariable
		{
			add_variable_to_head(&argsinsert, find_variable($1), &no_indicator);
			$$ = create_questionmarks($1, false);
		}
		;

indicator: cvariable				{ check_indicator((find_variable($1))->type); $$ = $1; }
		| SQL_INDICATOR cvariable	{ check_indicator((find_variable($2))->type); $$ = $2; }
		| SQL_INDICATOR name		{ check_indicator((find_variable($2))->type); $$ = $2; }
		;

cvariable:	CVARIABLE
		{
			/* As long as multidimensional arrays are not implemented we have to check for those here */
			char *ptr = $1;
			int brace_open=0, brace = false;

			for (; *ptr; ptr++)
			{
				switch (*ptr)
				{
					case '[':
							if (brace)
								mmfatal(PARSE_ERROR, "multidimensional arrays for simple data types are not supported");
							brace_open++;
							break;
					case ']':
							brace_open--;
							if (brace_open == 0)
								brace = true;
							break;
					case '\t':
					case ' ':
							break;
					default:
							if (brace_open == 0)
								brace = false;
							break;
				}
			}
			$$ = $1;
		}
		;

ecpg_param:	PARAM		{ $$ = make_name(); } ;

ecpg_bconst:	BCONST		{ $$ = $1; } ;

ecpg_fconst:	FCONST		{ $$ = make_name(); } ;

ecpg_sconst:	SCONST		{ $$ = $1; } ;

ecpg_xconst:	XCONST		{ $$ = $1; } ;

ecpg_ident:	IDENT		{ $$ = $1; }
		| CSTRING	{ $$ = make3_str(mm_strdup("\""), $1, mm_strdup("\"")); }
		;

quoted_ident_stringvar: name
			{ $$ = make3_str(mm_strdup("\""), $1, mm_strdup("\"")); }
		| char_variable
			{ $$ = make3_str(mm_strdup("("), $1, mm_strdup(")")); }
		;

/*
 * C stuff
 */

c_stuff_item: c_anything			{ $$ = $1; }
		| '(' ')'			{ $$ = mm_strdup("()"); }
		| '(' c_stuff ')'
			{ $$ = cat_str(3, mm_strdup("("), $2, mm_strdup(")")); }
		;

c_stuff: c_stuff_item			{ $$ = $1; }
		| c_stuff c_stuff_item
			{ $$ = cat2_str($1, $2); }
		;

c_list: c_term				{ $$ = $1; }
		| c_list ',' c_term	{ $$ = cat_str(3, $1, mm_strdup(","), $3); }
		;

c_term:  c_stuff			{ $$ = $1; }
		| '{' c_list '}'	{ $$ = cat_str(3, mm_strdup("{"), $2, mm_strdup("}")); }
		;

c_thing:	c_anything		{ $$ = $1; }
		|	'('		{ $$ = mm_strdup("("); }
		|	')'		{ $$ = mm_strdup(")"); }
		|	','		{ $$ = mm_strdup(","); }
		|	';'		{ $$ = mm_strdup(";"); }
		;

c_anything:  ecpg_ident				{ $$ = $1; }
		| Iconst			{ $$ = $1; }
		| ecpg_fconst			{ $$ = $1; }
		| ecpg_sconst			{ $$ = $1; }
		| '*'				{ $$ = mm_strdup("*"); }
		| '+'				{ $$ = mm_strdup("+"); }
		| '-'				{ $$ = mm_strdup("-"); }
		| '/'				{ $$ = mm_strdup("/"); }
		| '%'				{ $$ = mm_strdup("%"); }
		| NULL_P			{ $$ = mm_strdup("NULL"); }
		| S_ADD				{ $$ = mm_strdup("+="); }
		| S_AND				{ $$ = mm_strdup("&&"); }
		| S_ANYTHING			{ $$ = make_name(); }
		| S_AUTO			{ $$ = mm_strdup("auto"); }
		| S_CONST			{ $$ = mm_strdup("const"); }
		| S_DEC				{ $$ = mm_strdup("--"); }
		| S_DIV				{ $$ = mm_strdup("/="); }
		| S_DOTPOINT			{ $$ = mm_strdup(".*"); }
		| S_EQUAL			{ $$ = mm_strdup("=="); }
		| S_EXTERN			{ $$ = mm_strdup("extern"); }
		| S_INC				{ $$ = mm_strdup("++"); }
		| S_LSHIFT			{ $$ = mm_strdup("<<"); }
		| S_MEMBER			{ $$ = mm_strdup("->"); }
		| S_MEMPOINT			{ $$ = mm_strdup("->*"); }
		| S_MOD				{ $$ = mm_strdup("%="); }
		| S_MUL				{ $$ = mm_strdup("*="); }
		| S_NEQUAL			{ $$ = mm_strdup("!="); }
		| S_OR				{ $$ = mm_strdup("||"); }
		| S_REGISTER			{ $$ = mm_strdup("register"); }
		| S_RSHIFT			{ $$ = mm_strdup(">>"); }
		| S_STATIC			{ $$ = mm_strdup("static"); }
		| S_SUB				{ $$ = mm_strdup("-="); }
		| S_TYPEDEF			{ $$ = mm_strdup("typedef"); }
		| S_VOLATILE			{ $$ = mm_strdup("volatile"); }
		| SQL_BOOL			{ $$ = mm_strdup("bool"); }
		| ENUM_P			{ $$ = mm_strdup("enum"); }
		| HOUR_P			{ $$ = mm_strdup("hour"); }
		| INT_P				{ $$ = mm_strdup("int"); }
		| SQL_LONG			{ $$ = mm_strdup("long"); }
		| MINUTE_P			{ $$ = mm_strdup("minute"); }
		| MONTH_P			{ $$ = mm_strdup("month"); }
		| SECOND_P			{ $$ = mm_strdup("second"); }
		| SQL_SHORT			{ $$ = mm_strdup("short"); }
		| SQL_SIGNED			{ $$ = mm_strdup("signed"); }
		| SQL_STRUCT			{ $$ = mm_strdup("struct"); }
		| SQL_UNSIGNED			{ $$ = mm_strdup("unsigned"); }
		| YEAR_P			{ $$ = mm_strdup("year"); }
		| CHAR_P			{ $$ = mm_strdup("char"); }
		| FLOAT_P			{ $$ = mm_strdup("float"); }
		| TO				{ $$ = mm_strdup("to"); }
		| UNION				{ $$ = mm_strdup("union"); }
		| VARCHAR			{ $$ = mm_strdup("varchar"); }
		| '['				{ $$ = mm_strdup("["); }
		| ']'				{ $$ = mm_strdup("]"); }
		| '='				{ $$ = mm_strdup("="); }
		| ':'				{ $$ = mm_strdup(":"); }
		;

DeallocateStmt: DEALLOCATE prepared_name	{ check_declared_list($2); $$ = $2; }
		| DEALLOCATE PREPARE prepared_name	{ check_declared_list($3); $$ = $3; }
		| DEALLOCATE ALL					{ $$ = mm_strdup("all"); }
		| DEALLOCATE PREPARE ALL			{ $$ = mm_strdup("all"); }
		;

Iresult: Iconst						{ $$ = $1; }
		| '(' Iresult ')'			{ $$ = cat_str(3, mm_strdup("("), $2, mm_strdup(")")); }
		| Iresult '+' Iresult		{ $$ = cat_str(3, $1, mm_strdup("+"), $3); }
		| Iresult '-' Iresult		{ $$ = cat_str(3, $1, mm_strdup("-"), $3); }
		| Iresult '*' Iresult		{ $$ = cat_str(3, $1, mm_strdup("*"), $3); }
		| Iresult '/' Iresult		{ $$ = cat_str(3, $1, mm_strdup("/"), $3); }
		| Iresult '%' Iresult		{ $$ = cat_str(3, $1, mm_strdup("%"), $3); }
		| ecpg_sconst				{ $$ = $1; }
		| ColId						{ $$ = $1; }
		| ColId '(' var_type ')'	{ if (pg_strcasecmp($1, "sizeof") != 0)
							mmerror(PARSE_ERROR, ET_ERROR, "operator not allowed in variable definition");
						  else
							$$ = cat_str(4, $1, mm_strdup("("), $3.type_str, mm_strdup(")"));
						}
		;

execute_rest: /* EMPTY */	{ $$ = EMPTY; }
	| ecpg_using opt_ecpg_into  { $$ = EMPTY; }
	| ecpg_into ecpg_using  { $$ = EMPTY; }
	| ecpg_into				{ $$ = EMPTY; }
	;

ecpg_into: INTO into_list	{ $$ = EMPTY; }
	| into_descriptor		{ $$ = $1; }
	;

opt_ecpg_into:	/* EMPTY */	{ $$ = EMPTY; }
	| ecpg_into		{ $$ = $1; }
	;

ecpg_fetch_into: ecpg_into	{ $$ = $1; }
	| using_descriptor
	{
		struct variable *var;

		var = argsinsert->variable;
		remove_variable_from_list(&argsinsert, var);
		add_variable_to_head(&argsresult, var, &no_indicator);
		$$ = $1;
	}
	;

opt_ecpg_fetch_into:	/* EMPTY */	{ $$ = EMPTY; }
	| ecpg_fetch_into		{ $$ = $1; }
	;

%%

void base_yyerror(const char *error)
{
	/* translator: %s is typically the translation of "syntax error" */
	mmerror(PARSE_ERROR, ET_ERROR, "%s at or near \"%s\"",
			_(error), token_start ? token_start : base_yytext);
}

void parser_init(void)
{
 /* This function is empty. It only exists for compatibility with the backend parser right now. */
}
