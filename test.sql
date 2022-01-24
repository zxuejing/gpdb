create type special_agg_state as
(
    first_row_val  float8,
    second_row_val float8,
    proportion     float8,
    cnt            bigint
);

create function special_agg_trans(s special_agg_state, percent float8, a float8, total_rows bigint)
returns special_agg_state as
$$
declare
  first_row_id bigint;
  second_row_id bigint;
  cnt           bigint;
  proportion    float8;
  first_row_val float8;
  second_row_val float8;
begin
  cnt := s.cnt + 1;
  first_row_id := 1 + floor(percent * (total_rows - 1));
  second_row_id := 1 + ceil(percent * (total_rows - 1));
  proportion := (percent * (total_rows - 1)) - floor(percent * (total_rows - 1));
  if cnt = first_row_id then
      first_row_val := a;
  else
      first_row_val := s.first_row_val;
  end if;
  if cnt = second_row_id then
      second_row_val := a;
  else
       second_row_val := s.second_row_val;
  end if;
  return (first_row_val, second_row_val, proportion, cnt);
end;
$$ language plpgsql;

create function special_agg_final(s special_agg_state) returns float8 as
$$
begin
  if s.proportion > 0 then
      return s.first_row_val + (s.proportion*(s.second_row_val - s.first_row_val));
  else
      return s.first_row_val;
  end if;
end;
$$ language plpgsql;


create AGGREGATE special_agg(float8, float8, bigint)
(
    sfunc = special_agg_trans,
    stype = special_agg_state,
    finalfunc = special_agg_final,
    initcond = '(-1, -1, 0, 0)'
);

create table t(a float8);
insert into t select i from generate_series(1, 10)i;

select percentile_cont(0.3::float8) within group (order by a using > ) from t;
