"""New bounded service-batch plans; never coerce historical short/320 types."""
from dataclasses import dataclass

BACKENDS = ('openblas_2t', 'fpga_cached', 'fpga_cached', 'openblas_2t')

class BatchStop(RuntimeError):
    """Finish an entered complete request, then prohibit another request."""

@dataclass(frozen=True)
class BatchRequest:
    index: int
    shape: tuple
    jobs: int
    first_job_id: int
    input_id: int

@dataclass(frozen=True)
class BatchPolicy:
    profile: str
    enabled: bool = False

    def __post_init__(self):
        if self.enabled is not True or type(self.profile) is not str or self.profile not in ('smoke8', 'abba1808'):
            raise ValueError('explicit new batch profile/default-off required')

    @property
    def measured(self): return 2 if self.profile == 'smoke8' else 452
    @property
    def warmup(self): return 2 if self.profile == 'smoke8' else 4
    @property
    def per_window(self): return self.warmup + self.measured
    @property
    def pl_calls(self): return 2 * self.per_window

    def request(self, index):
        if type(index) is not int or not 0 <= index < self.pl_calls:
            raise ValueError('bounded explicit batch PL index required')
        return BatchRequest(index, (512,512,512), 64, 1+64*index, 42+index%2)

    def describe(self):
        return dict(profile=self.profile, backends=list(BACKENDS), shape_mnk=[512,512,512],
                    measured_per_window=self.measured, warmup_per_window=self.warmup,
                    measured_calls=4*self.measured, total_calls=4*self.per_window,
                    pl_calls=self.pl_calls, input_ids=[42,43],
                    input_sequence='42,43 alternating, reset at each window/phase',
                    stop_boundary='complete_request_no_next; stopped return not accepted',
                    scope='checked_service_batch_input_energy_candidate',
                    synchronized_task_energy_verified=False, formal_energy_input_accepted=False,
                    board_run_authorized=False, promotion=False)

def validate_policy(value):
    if type(value) is not BatchPolicy or value.enabled is not True:
        raise ValueError('exact new BatchPolicy required; historical policy forbidden')
    value.__post_init__()

def exact_int(value, low=0, high=10**21):
    if type(value) is not int or not low <= value <= high:
        raise ValueError('bounded exact integer required')
    return value
