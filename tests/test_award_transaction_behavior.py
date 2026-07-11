import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AWARD_TRANSACTION = ROOT / "Raid Management Addon" / "Services" / "Master" / "AwardTransaction.lua"


def run_lua(script):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", encoding="utf-8", delete=False) as handle:
        handle.write(script)
        script_path = Path(handle.name)
    try:
        subprocess.run(["lua.cmd", str(script_path)], check=True, cwd=ROOT)
    finally:
        script_path.unlink(missing_ok=True)


class AwardTransactionBehaviorTests(unittest.TestCase):
    def test_exposes_only_executing_lifecycle_and_preserves_terminal_behavior(self):
        path = str(AWARD_TRANSACTION).replace("\\", "\\\\")
        run_lua(textwrap.dedent(f"""
            local addon={{Services={{}}, Database={{}}}}
            addon.Services.EnsureNamespace=function(name)
                addon.Services[name]=addon.Services[name] or {{}}
                return addon.Services[name]
            end
            assert(loadfile("{path}"))("RMA", addon)
            local owner=addon.Services.Master.AwardTransaction
            assert(owner.Create==nil)

            local source={{slot=4}}
            local attempts=0
            local tx=owner.CreateExecuting({{
                transactionId="AT:1", rollSessionId="RS:1", itemKey="key:1",
                itemLink="item:1", winner="  Alice-Realm  ", source=source,
                executorContext={{executor="loot"}},
                onConfirm=function(snapshot, context)
                    attempts=attempts+1
                    assert(snapshot.state=="confirmed")
                    assert(context.commit==attempts)
                    if attempts < 3 then return false end
                    return true
                end,
            }})
            source.slot=99
            local initial=tx:GetState()
            assert(initial.state=="executing")
            assert(initial.transactionId=="AT:1" and initial.winner=="Alice-Realm")
            assert(initial.source.slot==4 and initial.executorContext.executor=="loot")
            assert(tx.Select==nil and tx.SelectWinner==nil and tx.BeginExecution==nil)

            assert(tx:Confirm({{commit=1}})==false and tx:GetState().state=="executing")
            assert(tx:Confirm({{commit=2}})==false and tx:GetState().state=="executing")
            assert(tx:Confirm({{commit=3}})==true and tx:GetState().state=="confirmed")
            assert(tx:Confirm({{commit=4}})==false and tx:Fail("late")==false and attempts==3)

            local failureAttempts=0
            local failed=owner.CreateExecuting({{
                onFail=function(reason, snapshot, context)
                    failureAttempts=failureAttempts+1
                    assert(reason==context.reason and snapshot.state=="failed")
                    return failureAttempts > 1
                end,
            }})
            assert(failed:Fail("retry", {{reason="retry"}})==false)
            assert(failed:GetState().state=="executing" and failed:GetState().failureReason==nil)
            assert(failed:Fail("final", {{reason="final"}})==true)
            assert(failed:GetState().state=="failed" and failed:GetState().failureReason=="final")
            assert(failed:Fail("duplicate")==false and failed:Confirm()==false and failureAttempts==2)
        """))


if __name__ == "__main__":
    unittest.main()
