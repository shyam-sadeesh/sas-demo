/*------------------------------------------------------------------
 * sales_summary.sas
 * Roll up enriched orders into monthly summary by segment and country
 *-----------------------------------------------------------------*/

libname mart "/data/mart";

proc sql;
    create table mart.sales_monthly as
    select
        put(order_date, yymmn6.) as month_id,
        country_code,
        customer_segment,
        count(distinct customer_id) as customers,
        count(*)                   as order_count,
        sum(net_amount)            as net_revenue,
        sum(gross_amount)          as gross_revenue,
        sum(discount_amount)       as total_discount
    from mart.orders_enriched
    group by 1, 2, 3;
quit;

proc sql;
    create table mart.top_segments as
    select
        month_id,
        customer_segment,
        sum(net_revenue) as segment_revenue
    from mart.sales_monthly
    group by month_id, customer_segment
    having segment_revenue > 100000
    order by month_id, segment_revenue desc;
quit;
