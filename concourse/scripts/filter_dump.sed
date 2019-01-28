# foreach database name
\@^\\connect (.*)$@{
  # adjust its format
  s@@ /* DATABASE: \1 */@;
  # copy it to hold space
  h;
}

# foreach insert command
\@^INSERT INTO @{
  # append the database name from hold space
  G;
  # join the two lines
  s@\n@@;
  # output it
  p;
}
