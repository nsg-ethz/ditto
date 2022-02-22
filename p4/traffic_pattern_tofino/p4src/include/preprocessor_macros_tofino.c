
#define TABLE_WITH_SINGLE_DO_ACTION(name) DEFAULT_ACTION_TABLE_WITH_ACTION( do_##name,name)

#define DEFAULT_ACTION_TABLE_WITH_ACTION(tablename,actionname) \
    table tablename { \
        actions { actionname; } \
        default_action: actionname; \
        size: 0; \
    }

