-- Additional destinations must use the same TikTok payload shape as first deliveries.
do $migration$
declare definition text;
begin
  definition := pg_get_functiondef('public.schedule_additional_platform_content(uuid,integer,public.social_platform,timestamptz,jsonb)'::regprocedure);
  if position('p_scheduled_for,5,settings)' in definition) = 0 then
    raise exception 'Unexpected additional-platform scheduling function definition';
  end if;
  execute replace(definition, 'p_scheduled_for,5,settings)', 'p_scheduled_for,5,case when p_platform = ''tiktok'' then jsonb_build_object(''settings'',settings) else settings end)');
end;
$migration$;
