"""Only an offline identity checker. No public run command or activation switch."""
import json
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
import outer_binding


def main():
    try:
        p=outer_binding.base.verifier.JsonParser()
        for name in ('manifest-sha','plan-sha','bank-sha'):p.add_argument('--'+name,required=True)
        args=p.parse_args()
        _,bank=outer_binding.check((args.manifest_sha,args.plan_sha,args.bank_sha))
        print(json.dumps(dict(check_pass=True,bank_pairs=len(bank),scope='offline bytes and private component binding only',
            fpga_block_bridge_implemented=True,cpu_block_bridge_implemented=True,controlled_round_candidate_implemented=True,
            board_activation_approved=False,
            runtime_arm_tested=False,run_ready=False,board_access=False,promotion=False)))
        return 0
    except (OSError,ValueError,RuntimeError,KeyError,TypeError,ImportError) as error:
        print(json.dumps(dict(check_pass=False,error=str(error),board_access=False)),file=sys.stderr)
        return 2


if __name__=='__main__':sys.exit(main())
