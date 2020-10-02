require 'icalendar'

class Webcal < ActiveRecord::Base

  belongs_to :user

  has_many :webcal_unit_exclusions, dependent: :destroy

  #
  # Array of valid units by which task reminders (alarms) can be set.
  # Documented at https://tools.ietf.org/html/rfc5545#section-3.3.6
  #
  def self.valid_time_units
    %w(W D H M)
  end

  #
  # Represents the presence of `reminder_time` and `reminder_unit`.
  #
  def reminder?
    reminder_time.present? && reminder_unit.present?
  end

  #
  # Retrieves `TaskDefinition`s that must be included in the generation of this webcal.
  # Eager loads all associations used by the `Webcal.to_ical` method.
  # Currently executes in just 1 SQL query!
  #
  def task_definitions
    TaskDefinition
      .joins(:unit, unit: :projects)
      .eager_load(:tasks)
      .includes(:unit, :tasks, unit: :projects)
      .where(
        projects: { user_id: user_id },
        units: { active: true }
      )
      .where.not(
        units: { id: WebcalUnitExclusion.where(webcal_id: id).select(:unit_id) } # exclude :webcal_unit_exclusions
      )
      .where('tasks.project_id is null or tasks.project_id = projects.id')   # eager_load only :tasks of :projects
      .where('? BETWEEN units.start_date AND units.end_date', Time.zone.now) # Current units
      .where('task_definitions.target_grade <= projects.target_grade')       # only :tasks of the targeted_grade or lower
  end

  #
  # Retrieves the event name for the specified task definition in the calendar.
  # Valid values for `variant` are,
  #   - 'start' retrieves the name for the _start event_
  #   - 'end' (default) retrieves the name for the _end event_
  #
  def event_name_for_task_definition(task_def, variant = 'end')
    name = "#{task_def.unit.code}: #{task_def.abbreviation}: #{task_def.name}"
    case variant
      when 'start' then "Start: #{name}"
      when 'end'   then (include_start_dates ? "End: #{name}" : name)
    end
  end

  #
  # Generates a single `Icalendar::Calendar` object from this `Webcal` including calendar events for the specified
  # collection of `TaskDefinition`s.
  #
  # The `unit` property of each `TaskDefinition` is accessed; ensure it is included to prevent N+1 selects. For example,
  #
  #   to_ical_with_task_definitions(
  #     TaskDefinition
  #       .joins(:unit)
  #       .includes(:unit)
  #   )
  #
  def to_ical(task_defs = task_definitions)
    ical = Icalendar::Calendar.new
    ical.publish
    ical.prodid = Doubtfire::Application.config.institution[:product_name]

    # Add iCalendar events for the specified definition.
    task_defs.each do |td|
      # Notes:
      # - Start and end dates of events are equal because the calendar event is expected to be an "all-day" event.
      # - iCalendar clients identify events across syncs by their UID property, which is currently the task definition
      #   ID prefixed with S- or E- based on whether it is a start or end event.

      ev_date_format = '%Y%m%d'
      ev_reminders = reminder?
      ev_reminder_trigger = "-PT#{reminder_time}#{reminder_unit}"

      # Add event for start date, if the user opted in.
      if include_start_dates
        ical.event do |ev|
          ev.uid = "S-#{td.id}"
          ev.summary = event_name_for_task_definition(td, 'start')
          ev.status = 'CONFIRMED'
          ev.dtstart = ev.dtend = Icalendar::Values::Date.new(td.start_date.strftime(ev_date_format))

          if ev_reminders
            ev.alarm do |a|
              a.action = 'DISPLAY'
              a.description = ev_summary
              a.trigger = ev_reminder_trigger
            end
          end
        end
      end

      # Add event for target/extended date.
      ical.event do |ev|
        ev.uid = "E-#{td.id}"
        ev.summary = event_name_for_task_definition(td, 'end')

        # Use extended date if available.
        ev_date = td.target_date
        ev_date += (td.tasks.first.extensions * 7).day if td.tasks.present?
        ev.dtstart = ev.dtend = Icalendar::Values::Date.new(ev_date.strftime(ev_date_format))

        if ev_reminders
          ev.alarm do |a|
            a.action = 'DISPLAY'
            a.description = ev_summary
            ev.status = 'CONFIRMED'
            a.trigger = ev_reminder_trigger
          end
        end
      end
    end

    # Specify refresh interval.
    refresh_interval = Icalendar::Values::Duration.new('1D')
    # https://docs.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-oxcical/1fc7b244-ecd1-4d28-ac0c-2bb4df855a1f
    ical.append_custom_property('X-PUBLISHED-TTL', refresh_interval)
    # https://tools.ietf.org/html/rfc7986#section-5.7
    ical.append_custom_property('REFRESH-INTERVAL', refresh_interval)

    ical
  end
end
