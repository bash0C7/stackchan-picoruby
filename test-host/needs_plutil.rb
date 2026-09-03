# LaunchAgent.write writes the job as JSON and has plutil convert it to a plist,
# because plutil does the XML escaping. plutil ships with macOS and exists
# nowhere else, so a test that reaches `write` cannot run on a Linux runner —
# and a launchd plist has nothing to prove there anyway.
#
# The tests that reach it say so with `needs_plutil`, and are omitted rather than
# failed where the tool is absent. Which tests those are was measured by making
# every plutil call fail and reading the list back, not by reading the sources:
# the dependency arrives through the library, so a test can need plutil without
# the word appearing anywhere in it.
module NeedsPlutil
  def needs_plutil
    return if system("which", "plutil", out: File::NULL, err: File::NULL)
    omit "plutil is macOS-only"
  end
end
