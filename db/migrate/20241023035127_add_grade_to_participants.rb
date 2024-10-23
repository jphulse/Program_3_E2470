class AddGradeToParticipants < ActiveRecord::Migration[7.0]
  def change
    add_column :participants, :grade, :float
  end
end
