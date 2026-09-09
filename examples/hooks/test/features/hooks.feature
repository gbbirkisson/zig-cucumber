Feature: Hook phases

  @io
  Scenario: Every phase fires around each step
    Given a report file
    When I record "one"
    And I record "two"
    Then the report reads "one,two"
    And the trace is "io,before,+step,-step,+step,-step,+step,-step,+step,-step,+step"

  @wip
  Scenario: A skipped step skips the tail
    Given a report file
    Then the trace is "before,+step,-step,+step"
    When I skip here
    Then this never runs
