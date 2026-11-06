"""Bounded device-container PCM routing; never claims decoder-native layout."""
import array
import math
from .hub import LiveFailure
from .pcm_v2 import LAYOUTS, RES_LAYOUTS


class VirtualRoutePlan:
    def __init__(self, layout, outputs, mode='synchronized', roles=None):
        if layout not in LAYOUTS or layout in RES_LAYOUTS:
            raise ValueError('unsupported virtual input layout')
        self.order = LAYOUTS[layout]
        self.outputs = tuple(outputs)
        if (not 1 <= len(self.outputs) <= 8 or len(set(self.outputs)) != len(self.outputs)
                or any(type(key) is not int or not 0 <= key < 2**32 for key in self.outputs)
                or mode not in ('cinema', 'synchronized')):
            raise ValueError('invalid virtual endpoint plan')
        roles = dict(roles or {})
        if set(roles) - set(self.outputs) or any(role not in self.order for role in roles.values()):
            raise ValueError('endpoint role missing from input container')
        rows = []
        self.actual_mode = 'stereo_downmix'
        if mode == 'cinema' and roles:
            # Partial assignment would silently lose dialog or surround content.
            if (set(roles) != set(self.outputs) or len(set(roles.values())) != len(roles)
                    or not (set(self.order) - {'LFE'}).issubset(set(roles.values()))):
                raise ValueError('cinema channel distribution requires complete unique endpoint roles')
            for key in self.outputs:
                row = tuple(float(label == roles[key]) for label in self.order)
                rows.extend((row, row))
            self.actual_mode = 'channel_distribution'
        else:
            left, right = self._downmix(layout)
            for _ in self.outputs:
                rows.extend((left, right))
        self.rows = tuple(rows)
        self.channels = len(self.rows)
        self.routes = {key: [2 * i, 2 * i + 1] for i, key in enumerate(self.outputs)}
        self.discarded = tuple(label for index, label in enumerate(self.order)
                               if all(row[index] == 0 for row in self.rows))

    def _downmix(self, layout):
        e = 1 / math.sqrt(2)
        if layout == 'mono':
            return (e,), (e,)
        left, right = {'FL': 1.0}, {'FR': 1.0}
        if 'FC' in self.order:
            left['FC'] = right['FC'] = e
        surrounds = [('SL', 'SR'), ('BL', 'BR')]
        active = [(l, r) for l, r in surrounds if l in self.order]
        for l, r in active:
            left[l] = right[r] = e / len(active)
        def normalized(weights):
            total = sum(weights.values())
            return tuple(weights.get(label, 0) / total for label in self.order)
        return normalized(left), normalized(right)

    def process(self, samples):
        channels = len(self.order)
        if (not samples or len(samples) % channels or len(samples) > 4096 * channels
                or any(not math.isfinite(v) or abs(v) > 1 for v in samples)):
            raise LiveFailure('invalid bounded multichannel PCM')
        output = array.array('f')
        for start in range(0, len(samples), channels):
            for row in self.rows:
                value = sum(samples[start + i] * gain for i, gain in enumerate(row))
                if not math.isfinite(value) or abs(value) > 1 + 1e-6:
                    raise LiveFailure('routing matrix exceeded normalized range')
                output.append(max(-1, min(1, value)))
        return output

    def report(self):
        return {'actual_mode': self.actual_mode, 'container_channel_order': list(self.order),
                'endpoint_output_order': list(self.outputs), 'routing_matrix': [list(row) for row in self.rows],
                'discarded_channels': list(self.discarded), 'lfe_policy': 'explicit_route_or_discard',
                'matrix_gain_policy': 'row_l1_normalized', 'native_claim': False}
