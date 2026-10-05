# Timed input scripts

Pass `--input-script PATH` to feed timed events while firmware runs. Times are
virtual board time; events are dispatched at the first board boundary at or
after their timestamp. Coordinates use panel pixels.

```text
at 2s tap 300 400
at 3s swipe 900 700 100 700 250ms
at 4s longpress 500 500 800ms
at 5s button power
```

`button power` aliases SW1 (P009, IRQ13), the primary user switch in this
board model. The modeled board has SW1 and SW2 and no separate power-key input.
The alias is a 100 ms active-low SW1 press.
