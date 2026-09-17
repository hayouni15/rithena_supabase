-- Keep the content lifecycle in sync when an asynchronous worker exhausts retries.
create or replace function public.fail_content_generation(
  p_content_item_id uuid,
  p_expected_revision integer,
  p_failure_code text,
  p_failure_message text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('rithena.lifecycle_transition', 'allowed', true);

  update public.content_items
  set status = 'failed',
      failure_code = nullif(left(coalesce(p_failure_code, 'generation_failed'), 120), ''),
      failure_message = nullif(left(coalesce(p_failure_message, 'Creative generation failed.'), 1000), '')
  where id = p_content_item_id
    and content_revision = p_expected_revision
    and status in ('generating', 'qa');
end;
$$;

revoke all on function public.fail_content_generation(uuid, integer, text, text)
  from public, anon, authenticated;
grant execute on function public.fail_content_generation(uuid, integer, text, text)
  to service_role;
