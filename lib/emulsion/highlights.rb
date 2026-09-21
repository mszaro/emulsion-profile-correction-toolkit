module Emulsion
  # What to do when a gain would push a channel past white.
  #
  # Lucky's sky arrives with its blue below its green, and the correction
  # rightly asks for about two stops of blue there. The sky is already near the
  # top of the range, so the lift runs blue into the ceiling and stops, while
  # green carries on up with the tone work: the sky lands pale cyan instead of
  # blue, and no later stage can undo it, because the clipped pixels no longer
  # differ from each other.
  #
  # A gain that cannot be given is taken from the other channels instead. The
  # pixel is scaled down until it fits, which keeps the colour the gains asked
  # for and spends brightness on it. Only pixels that would clip move at all,
  # and the easing holds the darkening to `limit` stops, so a bright subject
  # loses some light rather than turning into a silhouette.
  module Highlights
    module_function

    # `linear` is linear light, after the gains and before anything clamps it.
    def pull(linear, limit)
      return linear if limit.to_f <= 0

      peak = peak_of(linear)
      over = (peak < 1.0).ifthenelse(1.0, peak)
      stops = over.log / Math.log(2)
      eased = (stops / limit).tanh * limit
      linear * (eased * -Math.log(2)).exp
    end

    def peak_of(linear)
      highest = (linear[0] > linear[1]).ifthenelse(linear[0], linear[1])
      (highest > linear[2]).ifthenelse(highest, linear[2])
    end
  end
end
