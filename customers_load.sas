/*------------------------------------------------------------------
 * customers_load.sas
 * Load raw customers into WORK, iteratively enrich, then finalize to STG.
 * Each in-place update of WORK.CUSTOMERS produces a new version of the table.
 *-----------------------------------------------------------------*/

libname raw   oracle user=&ora_user. password=&ora_pwd.
              path=crm_prod schema=CRM;
libname stg   "/data/staging";

%include "/sas/macros/clean_text.sas";

/* Step 1 — pull from Oracle into WORK, basic cleansing */
proc sql;
    create table work.customers as
    select
        cust_id                  as customer_id,
        %clean_text(first_name)  as first_name,
        %clean_text(last_name)   as last_name,
        upcase(country)          as country_code,
        signup_date,
        status
    from raw.cust_master
    where signup_date >= '01JAN2020'd;
quit;

/* Step 2 — update WORK.CUSTOMERS in place: add risk flag */
data work.customers;
    set work.customers;
    length risk_flag $10;
    if      status = 'A' and signup_date < today() - 365 then risk_flag = 'TENURED';
    else if status = 'A'                                  then risk_flag = 'NEW';
    else                                                       risk_flag = 'INACTIVE';
run;

/* Step 3 — update WORK.CUSTOMERS in place: add segment */
data work.customers;
    set work.customers;
    length segment $20;
    if      risk_flag = 'TENURED' and country_code = 'US' then segment = 'PREMIUM_US';
    else if risk_flag = 'TENURED'                          then segment = 'PREMIUM_INTL';
    else if risk_flag = 'NEW'                              then segment = 'NEW_ACTIVE';
    else                                                        segment = 'INACTIVE';
run;

/* Step 4 — finalize to staging library */
proc sql;
    create table stg.customers as
    select
        customer_id,
        first_name,
        last_name,
        country_code,
        signup_date,
        risk_flag,
        segment,
        case when status = 'A' then 1 else 0 end as is_active
    from work.customers;
quit;
