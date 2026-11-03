"""Explicit fixed two-shape, three-backend plan; never a legacy policy cast."""
from dataclasses import dataclass

BACKENDS=('fpga_flat_baseline','fpga_flat_contiguous','openblas_2t','openblas_2t','fpga_flat_contiguous','fpga_flat_baseline')
SHAPES=(256,512)


def integer(value,low,high):
    if type(value) is not int or not low<=value<=high:
        raise ValueError('bounded non-bool integer required')
    return value


@dataclass(frozen=True)
class Geometry:
    dimension:int

    def __post_init__(self):
        if type(self.dimension) is not int or self.dimension not in SHAPES:
            raise ValueError('fixed 256/512 cube required')

    @property
    def shape(self):return (self.dimension,)*3
    @property
    def jobs(self):return (self.dimension//64)**2
    @property
    def input_bytes(self):return self.jobs*(64+2*64*self.dimension)
    @property
    def output_bytes(self):return self.dimension**2*4
    @property
    def macs(self):return self.dimension**3


@dataclass(frozen=True)
class Request:
    block_index:int
    local_index:int
    global_index:int
    dimension:int
    backend:str
    phase:str
    input_id:int
    jobs:int
    first_job_id:int

    @property
    def shape(self):return (self.dimension,)*3


@dataclass(frozen=True)
class ComparisonPolicy:
    block_index:int
    enabled:bool=False

    def __post_init__(self):
        if self.enabled is not True:raise ValueError('comparison default-off')
        integer(self.block_index,0,11)

    @property
    def dimension(self):return SHAPES[self.block_index//6]
    @property
    def backend(self):return BACKENDS[self.block_index%6]
    @property
    def geometry(self):return Geometry(self.dimension)
    @property
    def warmup(self):return 2
    @property
    def measured(self):return 4
    @property
    def per_block(self):return 6

    def request(self,index):
        integer(index,0,5)
        g=self.geometry
        return Request(self.block_index,index,6*self.block_index+index,self.dimension,
            self.backend,'warmup' if index<2 else 'formal',42+index%2,g.jobs,
            1+g.jobs*(6*self.block_index+index))


def validate_policy(policy):
    if type(policy) is not ComparisonPolicy:raise ValueError('exact ComparisonPolicy required')
    policy.__post_init__()


def validate_fpga_policy(policy):
    validate_policy(policy)
    if policy.backend not in ('fpga_flat_baseline','fpga_flat_contiguous'):
        raise ValueError('CPU block cannot acquire FPGA owner')


def describe_plan():
    from dataclasses import asdict
    return dict(schema='matrix-panel-threeway-plan-v1',dimensions=list(SHAPES),
        blocks=[dict(block_index=b,backend=ComparisonPolicy(b,True).backend,
                     dimension=ComparisonPolicy(b,True).dimension,
                     requests=[asdict(ComparisonPolicy(b,True).request(i)) for i in range(6)])
                for b in range(12)],formal_calls=48,warmup_calls=24,total_calls=72,
        stop_boundary='complete_request_no_next',automatic_retry=False,
        evidence_scope='complete_request_latency_diagnostic',energy_evaluated=False,
        board_run_authorized=False,promotion=False)
