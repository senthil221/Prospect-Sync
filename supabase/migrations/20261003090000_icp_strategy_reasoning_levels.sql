-- Per-method reasoning levels for the ICP check strategies.
--
-- Strict and Balanced run DeepSeek V4.1 Flash at low reasoning, Lenient at
-- high; GPT-6 Luna stays at low everywhere. The passes are copied onto
-- icp_validation_runs when a check starts, so checks already running keep the
-- levels they started with; only new checks use these.
--
-- worker/icp-validator-core.mjs (ICP_STRATEGIES) mirrors this table for the
-- dashboard; tests/icp-strategy-checks.test.mjs keeps the two identical.
create or replace function public.icp_strategy_passes_v1(p_strategy text)
returns table (pass_no smallint, model text, reasoning_effort text)
language sql
immutable
as $$
  select p.pass_no::smallint, p.model, p.effort
    from (values
      ('strict',   1, 'deepseek/deepseek-v4.1-flash', 'low'),
      ('strict',   2, 'openai/gpt-6-luna',            'low'),
      ('lenient',  1, 'deepseek/deepseek-v4.1-flash', 'high'),
      ('lenient',  2, 'deepseek/deepseek-v4.1-flash', 'high'),
      ('balanced', 1, 'deepseek/deepseek-v4.1-flash', 'low'),
      ('balanced', 2, 'deepseek/deepseek-v4.1-flash', 'low'),
      ('balanced', 3, 'openai/gpt-6-luna',            'low')
    ) as p(strategy, pass_no, model, effort)
   where p.strategy = p_strategy
   order by p.pass_no
$$;

revoke execute on function public.icp_strategy_passes_v1(text) from public, anon, authenticated;
grant execute on function public.icp_strategy_passes_v1(text) to service_role;

do $$
begin
  if (select string_agg(model || ':' || reasoning_effort, ',' order by pass_no) from public.icp_strategy_passes_v1('strict'))
       <> 'deepseek/deepseek-v4.1-flash:low,openai/gpt-6-luna:low'
    or (select string_agg(model || ':' || reasoning_effort, ',' order by pass_no) from public.icp_strategy_passes_v1('balanced'))
       <> 'deepseek/deepseek-v4.1-flash:low,deepseek/deepseek-v4.1-flash:low,openai/gpt-6-luna:low'
    or (select string_agg(model || ':' || reasoning_effort, ',' order by pass_no) from public.icp_strategy_passes_v1('lenient'))
       <> 'deepseek/deepseek-v4.1-flash:high,deepseek/deepseek-v4.1-flash:high' then
    raise exception 'ICP strategy reasoning levels did not apply';
  end if;
end $$;
