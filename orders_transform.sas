/*------------------------------------------------------------------
 * orders_transform.sas
 * Clean raw orders, then enrich by joining the finalized stg.customers
 *-----------------------------------------------------------------*/

libname raw  oracle user=&ora_user. password=&ora_pwd.
             path=ord_prod schema=ORDERS;
libname stg  "/data/staging";
libname mart "/data/mart";

/* Step 5 */
proc sql;
    create table stg.orders_clean as
    select
        o.order_id,
        o.cust_id        as customer_id,
        o.order_dt       as order_date,
        o.gross_amt      as gross_amount,
        o.discount_amt   as discount_amount,
        (o.gross_amt - o.discount_amt) as net_amount,
        o.currency_cd    as currency_code
    from raw.orders o
    where o.order_status not in ('CANCELLED', 'REJECTED');
quit;

/* Step 6 — single join now that stg.customers carries risk_flag and segment */
proc sql;
    create table mart.orders_enriched as
    select
        o.*,
        c.country_code,
        c.risk_flag,
        c.segment        as customer_segment
    from stg.orders_clean o
    left join stg.customers c
        on o.customer_id = c.customer_id;
quit;
