"""Explicit new policy dispatch. No original-old backend or automatic fallback."""
from comparison_policy import validate_fpga_policy
from comparison_call import ComparisonCall
from materialized_call_candidate import ContiguousComparisonCall


def call_type(policy):
    validate_fpga_policy(policy)
    return (ComparisonCall if policy.backend=='fpga_flat_baseline' else ContiguousComparisonCall)
