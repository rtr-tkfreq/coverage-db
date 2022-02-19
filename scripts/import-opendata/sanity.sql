select count(*) as count,operator,rfc_date from cov_mno group by operator,rfc_date order by operator;
select count(*) as err_dl ,operator from cov_mno where dl_max < dl_normal group by operator;
select count(*) as err_ul ,operator from cov_mno where ul_max < ul_normal group by operator;
select count(*) as err_null ,operator from cov_mno where dl_normal is null or ul_normal is null 
       or dl_max is null or ul_max is null or dl_normal=0 or ul_normal=0 or dl_max=0 or ul_max=0 group by operator;


