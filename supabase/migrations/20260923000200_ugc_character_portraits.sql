-- Project-hosted previews keep the catalog visual without coupling selection UI
-- to private storage or a paid avatar provider.
update public.ugc_characters set portrait_url = case slug
  when 'maya-warm-guide' then '/ugc-characters/maya.png'
  when 'jordan-practical-expert' then '/ugc-characters/jordan.png'
  when 'nia-energetic-creator' then '/ugc-characters/nia.png'
  when 'alex-premium-minimal' then '/ugc-characters/alex.png'
  when 'sofia-friendly-founder' then '/ugc-characters/sofia.png'
  when 'marcus-confident-coach' then '/ugc-characters/marcus.png'
  else portrait_url
end;
