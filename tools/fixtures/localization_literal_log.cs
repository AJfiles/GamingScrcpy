// POSITIVE-CONTROL FIXTURE for gate section 15.
// This line is supposed to FAIL the hardcoded-string check. Never wired into
// the build: launcher/*.cs is what the gate scans.
//   Log("this English string never went through Loc");
class Fixture
{
    void Broken() => Log("this English string never went through Loc");
}
