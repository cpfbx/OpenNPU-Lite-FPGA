"""Review-only candidate CLI. NOT approved for bx board execution yet."""
from pathlib import Path
import json
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import outer_binding as binding

def main():
    try:
        p=binding.base.verifier.JsonParser()
        p.add_argument('--config',type=Path,required=True);p.add_argument('--config-sha',required=True)
        p.add_argument('--evidence-dir',type=Path,required=True)
        p.add_argument('--enable-unapproved-candidate',action='store_true')
        args=p.parse_args()
        # Refuse PC BEFORE asking for confirmation or creating any files.
        if not args.enable_unapproved_candidate:raise ValueError('review candidate default-off; not activation approval')
        binding.require_arm()
        if input('bx only: separately reviewed exact candidate approved? Type PANEL72: ')!='PANEL72':
            raise ValueError('exact fresh bx confirmation required')
        binding.base.configure()
        from round_launcher import launch
        result=launch(args.config,args.config_sha,args.evidence_dir,enabled=True,confirmed=True)
        print(json.dumps(result,allow_nan=False));return 0
    except (OSError,ValueError,RuntimeError,KeyError,TypeError,ImportError,EOFError) as error:
        print(json.dumps(dict(error_type=type(error).__name__,error=str(error),promotion=False)),file=sys.stderr);return 2

if __name__=='__main__':sys.exit(main())
