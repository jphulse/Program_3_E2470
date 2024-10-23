class AddGradeForSubmissionAndCommentForSubmissionInTeamsTable < ActiveRecord::Migration[7.0]
  def change
    add_column :teams, :grade_for_submission, :integer, default: nil
    add_column :teams, :comment_for_submission, :text, default: nil
  end
end
