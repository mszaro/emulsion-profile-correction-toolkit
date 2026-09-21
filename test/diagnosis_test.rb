require_relative "test_helper"

class DiagnosisTest < Minitest::Test
  W = 240
  H = 160

  def reference
    Emulsion::Reference.load("fujifilm-superia")
  end

  # A busy frame with a cast of the given stops and, with `red_floor`, red
  # crushed to black in the darkest patches, which is how Phoenix scans.
  def frame(cast: [0.0, 0.0], red_floor: nil, seed: 1)
    noise = Random.new(seed)
    TestImages.linear_image(W, H) do |x, y|
      level = 0.02 + 0.5 * (((x / 7) + (y / 5)) % 5) / 4.0 + noise.rand * 0.02
      red = level * 2**cast[0]
      red = 0.0 if red_floor && level < 0.1
      [red, level, level * 2**cast[1]]
    end
  end

  def test_ramp_runs_from_absent_to_present
    assert_equal 0.0, Emulsion::Diagnosis.ramp(0.1, 0.3, 0.45)
    assert_equal 1.0, Emulsion::Diagnosis.ramp(0.6, 0.3, 0.45)
    assert_in_delta 0.5, Emulsion::Diagnosis.ramp(0.375, 0.3, 0.45), 1e-9
  end

  # A roll whose frames all carry the same cast has nothing for a frame
  # balance to do, however far the cast is from the reference.
  def test_a_steady_roll_reads_no_drift
    frames = 6.times.map { |n| frame(cast: [0.4, -0.3], seed: n) }
    drift, = Emulsion::Diagnosis.lab_drift(frames, reference)
    assert_operator drift, :<, Emulsion::Diagnosis::LINES[:lab_drift][0]
  end

  def test_a_lab_that_moved_every_frame_reads_as_drift
    casts = [[0.8, -0.6], [-0.7, 0.6], [0.6, 0.7], [-0.6, -0.7], [0.9, 0.0], [-0.9, 0.0]]
    frames = casts.each_with_index.map { |cast, n| frame(cast: cast, seed: n) }
    drift, = Emulsion::Diagnosis.lab_drift(frames, reference)
    assert_operator drift, :>, Emulsion::Diagnosis::LINES[:lab_drift][1]
  end

  def test_a_crushed_channel_is_named_on_a_frame
    assert_in_delta 1.0, Emulsion::Diagnosis.crushed(frame(red_floor: true)), 0.01
    assert_in_delta 0.0, Emulsion::Diagnosis.crushed(frame), 0.01
  end

  # The audit says LEFT when a fault is there and its stage is off, and
  # handled once the stage is on.
  def test_the_audit_names_a_stage_left_undone
    frames = 6.times.map { |n| frame(red_floor: true, seed: n) }
    diagnosis = Emulsion::Diagnosis.new(frames, reference, nil)
    assert diagnosis[:crushed_channel].present?
    audit = diagnosis.audit(Emulsion::DEFAULTS.merge(reference: "fujifilm-superia", roll_balance: 0.0))
    cast_line = audit.lines.find { |line| line.include?(Emulsion::Diagnosis::LABELS[:cast]) }
    refute_nil cast_line
    assert_match(/quiet|LEFT/, cast_line)
  end

  def test_the_audit_flags_a_stage_that_would_make_things_worse
    flat = Emulsion::FlatField.new([[1.0, -0.8, 0.0], [1.0, -0.2, 0.0], [1.0, -0.1, 0.0]])
    diagnosis = Emulsion::Diagnosis.new(6.times.map { |n| frame(seed: n) }, reference, flat)
    line = diagnosis.audit(Emulsion::DEFAULTS.merge(flat_field: 1.0)).lines.last
    assert_match(/AT RISK/, line)
    line = diagnosis.audit(Emulsion::DEFAULTS.merge(flat_field: 0.0)).lines.last
    assert_match(/handled/, line)
  end
end
